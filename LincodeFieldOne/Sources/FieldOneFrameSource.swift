import FieldOneSDK
import Foundation
import ImageIO
import UIKit

#if canImport(FieldOneVLCKit)
import FieldOneVLCKit
#endif

/// Live video and camera photos from ENDLESSRIVER FIELD ONE, through SDK 1.3.
///
/// One connection owns exactly one client, one device-control session, one
/// video view and one preview-lifecycle adapter, as the SDK requires. Live
/// inference reads small VLC snapshots through `FieldOneFrameTap`. The shutter
/// asks the camera itself for a JPEG, which the SDK returns as original bytes
/// after stopping and restarting the preview around the still-mode change.
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
    private(set) var capabilities: FieldOneDeviceCapabilities?
    private(set) var deviceHealth: FieldOneDeviceHealth?
    /// Why the shutter falls back to a live frame, or nil when photos work.
    private(set) var photoUnavailableReason: String?

    private var client: FieldOneClient?
    private var preview: (any FieldOnePreviewLifecycle)?
    private var connectTask: Task<Void, Never>?
    private var activeCapture: Task<CapturedStill, Error>?
    private var cleanupTask: Task<Void, Never>?
    /// Honours the camera's own cooldown after a wedged or busy response.
    private var retryAllowedAt = Date.distantPast
    private var generation = 0

    #if canImport(FieldOneVLCKit)
    private lazy var videoView = FieldOneVideoView(frame: .zero)
    #endif
    private var tap: FieldOneFrameTap?

    var capturesCameraPhotos: Bool {
        state.isStreaming && preview != nil && photoUnavailableReason == nil
    }

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

    // MARK: - Connection

    func start() async {
        #if canImport(FieldOneVLCKit)
        // Let the previous connection finish closing before opening a new one.
        await cleanupTask?.value
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
        generation += 1
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
            try Task.checkCancellation()
            self.connection = connection

            let control = FieldOneDeviceControl(host: connection.device.host)
            deviceControl = control

            state = .preparing("Reading camera")
            await readCameraReadiness(control)
            try Task.checkCancellation()

            state = .preparing("Starting video")
            _ = try await videoView.playFirstAvailable(connection)
            try Task.checkCancellation()
            preview = videoView.previewLifecycle(for: connection)

            let tap = FieldOneFrameTap(player: videoView.mediaPlayer)
            tap.samplingRate = samplingRate
            tap.onFrame = { [weak self] frame in self?.onFrame?(frame) }
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

    /// Storage and capabilities decide whether the shutter can take a camera
    /// photo. Video still starts when these reads fail; only photos are gated.
    private func readCameraReadiness(_ control: FieldOneDeviceControl) async {
        do {
            let health = try await control.probe()
            deviceHealth = health
            let capabilities = try await control.getCapabilities()
            self.capabilities = capabilities

            if !health.cardUsable {
                photoUnavailableReason = "Insert a usable storage card to take camera photos."
            } else if !capabilities.presentMomentCameraJPEG {
                photoUnavailableReason = "This camera's firmware does not offer camera photos."
            } else {
                photoUnavailableReason = nil
            }
        } catch {
            photoUnavailableReason = "Camera control did not respond: \(error.localizedDescription)"
        }
    }
    #endif

    func stop() {
        generation += 1
        let ownGeneration = generation
        connectTask?.cancel()
        connectTask = nil

        // Per the SDK lifecycle: cancel the active capture, let it unwind,
        // then stop the player, close control and disconnect.
        let capture = activeCapture
        capture?.cancel()
        activeCapture = nil
        tap?.stop()
        tap = nil

        let control = deviceControl
        let client = client
        deviceControl = nil
        self.client = nil
        preview = nil
        connection = nil
        capabilities = nil
        deviceHealth = nil
        photoUnavailableReason = nil
        displaySize = nil
        state = .idle

        cleanupTask = Task { @MainActor [weak self] in
            _ = await capture?.result
            #if canImport(FieldOneVLCKit)
            if let self, self.generation == ownGeneration { self.videoView.stop() }
            #endif
            await control?.close()
            await client?.disconnect()
            self?.cleanupTask = nil
        }
    }

    /// Confirms the camera is still reachable after a background/foreground cycle.
    func health() async -> FieldOneHealth? {
        await client?.health()
    }

    // MARK: - Capture

    func captureStill(
        progress: @escaping @Sendable @MainActor (CaptureProgress) -> Void
    ) async throws -> CapturedStill {
        guard state.isStreaming else { throw FrameSourceError.notStreaming }
        guard activeCapture == nil else { throw FieldOnePhotoError.busy }

        let task = Task { @MainActor in
            if self.capturesCameraPhotos {
                return try await self.takeCameraPhoto(progress: progress)
            }
            return try await self.liveFrame()
        }
        activeCapture = task
        defer { if activeCapture == task { activeCapture = nil } }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    #if canImport(FieldOneVLCKit)
    private func takeCameraPhoto(
        progress: @escaping @Sendable @MainActor (CaptureProgress) -> Void
    ) async throws -> CapturedStill {
        guard let control = deviceControl, let preview else { throw FrameSourceError.notStreaming }
        let wait = retryAllowedAt.timeIntervalSinceNow
        guard wait <= 0 else { throw FieldOnePhotoError.coolingDown(seconds: Int(wait.rounded(.up))) }

        // The SDK stops and restarts VLC around the still-mode change; keep the
        // inference tap from requesting snapshots of a player in transition.
        tap?.pause()
        defer { if state.isStreaming { tap?.start() } }

        progress(.takingPhoto)
        let result: FieldOneHighQualityCaptureResult
        do {
            result = try await control.captureHighQualityNow(
                output: .bytes,
                preview: preview,
                onProgress: { received, total in
                    Task { @MainActor in progress(.downloading(received: received, total: total)) }
                }
            )
        } catch let error as PTPSessionError {
            if let seconds = error.retryAfter {
                retryAllowedAt = Date().addingTimeInterval(seconds)
            }
            throw FieldOnePhotoError(error)
        }

        guard let jpeg = result.jpegData else { throw FieldOnePhotoError.noImageData }

        // A 12 MP decode is tens of megabytes of pixels; keep it off the main actor.
        let image = try await Task.detached(priority: .userInitiated) {
            try StillImageDecoder.uprightImage(from: jpeg)
        }.value

        return CapturedStill(
            frame: VideoFrame(
                image: .cgImage(image),
                size: CGSize(width: image.width, height: image.height),
                orientation: .up,
                capturedAt: CACurrentMediaTime()
            ),
            provenance: .cameraPhoto,
            encodedJPEG: jpeg,
            camera: CameraPhotoMetadata(
                handle: result.handle,
                filename: result.media.filename,
                byteCount: jpeg.count,
                width: image.width,
                height: image.height,
                latencyMs: result.latencyMs,
                deviceCapturedAt: result.media.deviceCapturedAt
            )
        )
    }

    /// Fallback when the camera cannot take a photo: the current live frame,
    /// labelled as such.
    private func liveFrame() async throws -> CapturedStill {
        let url = try await videoView.captureSnapshot()
        defer { try? FileManager.default.removeItem(at: url) }
        guard let image = FieldOneFrameTap.loadImage(at: url) else {
            throw FrameSourceError.stillUnavailable
        }
        return CapturedStill(
            frame: VideoFrame(
                image: .cgImage(image),
                size: CGSize(width: image.width, height: image.height),
                orientation: .up,
                capturedAt: CACurrentMediaTime()
            ),
            provenance: .livePreviewFrame,
            encodedJPEG: nil,
            camera: nil
        )
    }
    #else
    private func takeCameraPhoto(
        progress: @escaping @Sendable @MainActor (CaptureProgress) -> Void
    ) async throws -> CapturedStill {
        throw FrameSourceError.unsupportedOnThisDevice("FIELD ONE is unavailable in this build.")
    }

    private func liveFrame() async throws -> CapturedStill {
        throw FrameSourceError.unsupportedOnThisDevice("FIELD ONE is unavailable in this build.")
    }
    #endif
}

/// Camera photo failures, worded for the operator per the SDK's guidance.
enum FieldOnePhotoError: LocalizedError {
    case recordingInProgress
    case outcomeUncertain(String)
    case storage(String)
    case cameraUnavailable(String)
    case coolingDown(seconds: Int)
    case busy
    case noImageData
    case other(String)

    init(_ error: PTPSessionError) {
        switch error.code {
        case .recordingInProgress:
            self = .recordingInProgress
        case .captureNotProduced, .transferInterrupted:
            self = .outcomeUncertain(error.message)
        case .cardUnusable, .storeFull:
            self = .storage(error.message)
        case .deviceWedged, .cameraGone, .busyElsewhere:
            self = .cameraUnavailable(error.message)
        case .deviceBusy:
            self = .busy
        default:
            self = .other(error.message)
        }
    }

    var errorDescription: String? {
        switch self {
        case .recordingInProgress:
            "Stop recording to take an image."
        case .outcomeUncertain(let detail):
            "\(detail) The camera may already have saved this photo to its card, so check before taking another."
        case .storage(let detail):
            detail
        case .cameraUnavailable(let detail):
            "\(detail) Reconnect the camera if this continues."
        case .coolingDown(let seconds):
            "The camera is recovering. Try again in \(seconds) s."
        case .busy:
            "The camera is still finishing the previous photo."
        case .noImageData:
            "The camera finished the photo but returned no image data."
        case .other(let detail):
            detail
        }
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
        guard loop == nil else { return }
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

    /// Stops sampling without discarding the tap.
    func pause() {
        loop?.cancel()
        loop = nil
    }

    func stop() {
        pause()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func grab() async -> VideoFrame? {
        guard player.state == .playing, player.hasVideoOut else { return nil }

        let url = directory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        player.saveVideoSnapshot(at: url.path, withWidth: Self.inferenceWidth, andHeight: 0)

        // VLC creates the file before the PNG is fully written, so a file that
        // exists is not yet a frame. Retry the decode until it succeeds.
        let deadline = CACurrentMediaTime() + 0.6
        while CACurrentMediaTime() < deadline {
            if Task.isCancelled { return nil }
            if FileManager.default.fileExists(atPath: url.path) {
                let decode = Task.detached(priority: .userInitiated) { Self.loadImage(at: url) }
                if let image = await decode.value {
                    return VideoFrame(
                        image: .cgImage(image),
                        size: CGSize(width: image.width, height: image.height),
                        orientation: .up,
                        capturedAt: CACurrentMediaTime()
                    )
                }
            }
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        return nil
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
    func pause() {}
    func stop() {}
    nonisolated static func loadImage(at url: URL) -> CGImage? { nil }
}
#endif
