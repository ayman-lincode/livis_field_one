import FieldOneSDK
import Foundation
import ImageIO
import UIKit

#if canImport(FieldOneVLCKit)
import FieldOneVLCKit
#endif

/// Live video from ENDLESSRIVER FIELD ONE, through the client SDK.
///
/// The SDK renders RTSP with VLCKit into its own view, and exposes decoded
/// frames only as snapshot files. `FieldOneFrameTap` turns that into a frame
/// stream by asking the player for a small snapshot on a timer, which is what
/// feeds live inference. The capture action takes the SDK's own full 1280x720
/// snapshot instead, so saved evidence is at the stream's native resolution.
@MainActor
final class FieldOneFrameSource: FrameSource {
    let kind: FrameSourceKind = .fieldOne

    private(set) var state: SourceState = .idle {
        didSet { onStateChange?(state) }
    }
    /// The stream's native size, known only once video is actually decoding.
    private(set) var displaySize: CGSize?

    var onStateChange: ((SourceState) -> Void)?
    var onFrame: ((VideoFrame) -> Void)?

    var samplingRate: Double = 8 {
        didSet { tap?.samplingRate = samplingRate }
    }

    /// Set before `start()` to let the SDK show the iOS join-Wi-Fi prompt.
    var joinWiFiAutomatically: Bool = false
    /// Set before `start()` to pin a known camera address.
    var preferredHost: String?

    private(set) var connection: FieldOneConnection?
    private(set) var deviceControl: FieldOneDeviceControl?

    private var client: FieldOneClient?
    private var connectTask: Task<Void, Never>?

    #if canImport(FieldOneVLCKit)
    private lazy var videoView = FieldOneVideoView(frame: .zero)
    private var tap: FieldOneFrameTap?
    #else
    private var tap: FieldOneFrameTap?
    #endif

    func makePreviewView() -> UIView {
        #if canImport(FieldOneVLCKit)
        videoView.backgroundColor = .black
        return videoView
        #else
        let view = UIView()
        view.backgroundColor = .black
        return view
        #endif
    }

    func start() async {
        #if canImport(FieldOneVLCKit)
        connectTask?.cancel()
        let task = Task { @MainActor in await self.performStart() }
        connectTask = task
        await task.value
        #else
        state = .failed(
            "This build was made without the FieldOneVLCKit module, so FIELD ONE video is unavailable."
        )
        #endif
    }

    #if canImport(FieldOneVLCKit)
    private func performStart() async {
        let configuration = FieldOneConfiguration(
            preferredHost: preferredHost?.isEmpty == false ? preferredHost : nil,
            joinWiFiAutomatically: joinWiFiAutomatically
        )
        let client = FieldOneClient(configuration: configuration)
        self.client = client

        state = .preparing(
            joinWiFiAutomatically ? "Joining FIELD ONE Wi-Fi" : "Looking for FIELD ONE"
        )

        do {
            let connection = try await client.connect()
            guard !Task.isCancelled else { return }
            self.connection = connection

            state = .preparing("Starting video")
            _ = try await videoView.playFirstAvailable(connection)
            guard !Task.isCancelled else { return }

            deviceControl = FieldOneDeviceControl(host: connection.device.host)

            let tap = FieldOneFrameTap(player: videoView.mediaPlayer)
            tap.samplingRate = samplingRate
            tap.onFrame = { [weak self] frame in
                self?.onFrame?(frame)
            }
            self.tap = tap
            tap.start()

            displaySize = CGSize(
                width: FieldOneProduct.videoWidth,
                height: FieldOneProduct.videoHeight
            )
            state = .streaming
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
    #endif

    func stop() {
        connectTask?.cancel()
        connectTask = nil
        tap?.stop()
        tap = nil
        #if canImport(FieldOneVLCKit)
        videoView.stop()
        #endif
        displaySize = nil
        let control = deviceControl
        let client = client
        deviceControl = nil
        self.client = nil
        connection = nil
        Task.detached {
            await control?.close()
            await client?.disconnect()
        }
        state = .idle
    }

    /// Confirms the camera is still reachable after a background/foreground cycle.
    func health() async -> FieldOneHealth? {
        await client?.health()
    }

    func captureStill() async throws -> VideoFrame {
        #if canImport(FieldOneVLCKit)
        guard state.isStreaming else { throw FrameSourceError.notStreaming }
        let url = try await videoView.captureSnapshot()
        defer { try? FileManager.default.removeItem(at: url) }
        guard let image = FieldOneFrameTap.loadImage(at: url) else {
            throw FrameSourceError.stillUnavailable
        }
        return VideoFrame(
            image: .cgImage(image),
            size: CGSize(width: image.width, height: image.height),
            orientation: .up,
            capturedAt: CACurrentMediaTime()
        )
        #else
        throw FrameSourceError.unsupportedOnThisDevice(
            "FIELD ONE video is unavailable in this build."
        )
        #endif
    }
}

#if canImport(FieldOneVLCKit)
import VLCKit

/// Pulls decoded frames out of the SDK's VLC player for inference.
///
/// VLCKit exposes no pixel-buffer callback, so the only way to reach a decoded
/// frame is `saveVideoSnapshot`. Snapshots are requested at a reduced width so
/// the PNG encode stays cheap; height 0 asks VLC to preserve the aspect ratio.
@MainActor
final class FieldOneFrameTap {
    /// Snapshot width used for inference. Larger than any common model input,
    /// so downscaling to the model happens once, inside Vision.
    static let inferenceWidth: Int32 = 640

    var samplingRate: Double = 8
    var onFrame: ((VideoFrame) -> Void)?

    private let player: VLCMediaPlayer
    private let directory: URL
    private var loop: Task<Void, Never>?

    init(player: VLCMediaPlayer) {
        self.player = player
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("field-one-frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func start() {
        stop()
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let started = CACurrentMediaTime()
                if let frame = await self.grab() {
                    self.onFrame?(frame)
                }
                let interval = 1.0 / max(1, self.samplingRate)
                let remaining = interval - (CACurrentMediaTime() - started)
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                } else {
                    await Task.yield()
                }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func grab() async -> VideoFrame? {
        guard player.state == .playing, player.hasVideoOut else { return nil }

        let url = directory.appendingPathComponent("\(UUID().uuidString).png")
        player.saveVideoSnapshot(at: url.path, withWidth: Self.inferenceWidth, andHeight: 0)

        // VLC writes the snapshot on its video-output thread, so poll briefly.
        let deadline = CACurrentMediaTime() + 0.6
        while CACurrentMediaTime() < deadline {
            if Task.isCancelled { return nil }
            if FileManager.default.fileExists(atPath: url.path) { break }
            try? await Task.sleep(nanoseconds: 8_000_000)
        }

        // Decode off the main actor: the PNG the snapshot produces is small but
        // the app has a live video view to keep smooth.
        let decode = Task.detached(priority: .userInitiated) { () -> CGImage? in
            defer { try? FileManager.default.removeItem(at: url) }
            return Self.loadImage(at: url)
        }
        guard let image = await decode.value else { return nil }
        return VideoFrame(
            image: .cgImage(image),
            size: CGSize(width: image.width, height: image.height),
            orientation: .up,
            capturedAt: CACurrentMediaTime()
        )
    }

    nonisolated static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary)
    }
}
#else
/// Stand-in so the app still builds when the optional video module is absent.
@MainActor
final class FieldOneFrameTap {
    var samplingRate: Double = 8
    var onFrame: ((VideoFrame) -> Void)?
    func start() {}
    func stop() {}
    nonisolated static func loadImage(at url: URL) -> CGImage? { nil }
}
#endif
