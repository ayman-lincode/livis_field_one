@preconcurrency import AVFoundation
import CoreImage
import Foundation
import UIKit

/// Live video from this iPhone's own camera.
///
/// Present so a model can be validated on the bench before FIELD ONE hardware
/// is attached. Preview and inference share one `AVCaptureVideoDataOutput`, so
/// a box drawn over the preview and a box burnt into a captured file come from
/// exactly the same pixels.
@MainActor
final class DeviceCameraFrameSource: NSObject, FrameSource {
    let kind: FrameSourceKind = .deviceCamera

    private(set) var state: SourceState = .idle {
        didSet { onStateChange?(state) }
    }
    private(set) var displaySize: CGSize?

    var onStateChange: ((SourceState) -> Void)?
    var onFrame: ((VideoFrame) -> Void)?
    var samplingRate: Double = 15

    /// Which camera to open. Takes effect on the next `start()`.
    var position: AVCaptureDevice.Position = .back

    // The capture session and its output are touched only on `queue`, never
    // concurrently, so they are deliberately outside the main actor.
    nonisolated(unsafe) private let session = AVCaptureSession()
    nonisolated(unsafe) private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.lincode.fieldone.camera", qos: .userInitiated)
    private var previewView: SampleBufferPreviewView?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var lastDelivered: CFTimeInterval = 0
    private var pendingStill: CheckedContinuation<VideoFrame, Error>?
    private var stillTimeout: Task<Void, Never>?

    func makePreviewView() -> UIView {
        let view = SampleBufferPreviewView()
        previewView = view
        return view
    }

    func start() async {
        guard await requestAccess() else {
            state = .failed(FrameSourceError.permissionDenied.localizedDescription)
            return
        }

        state = .preparing("Opening camera")
        guard await configureSession() else { return }

        await withCheckedContinuation { continuation in
            queue.async { [session] in
                if !session.isRunning { session.startRunning() }
                continuation.resume()
            }
        }
    }

    func stop() {
        stillTimeout?.cancel()
        stillTimeout = nil
        if let pending = pendingStill {
            pendingStill = nil
            pending.resume(throwing: FrameSourceError.notStreaming)
        }
        rotationObservation?.invalidate()
        rotationObservation = nil
        rotationCoordinator = nil
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
        previewView?.flush()
        state = .idle
    }

    func captureStill() async throws -> VideoFrame {
        guard state.isStreaming else { throw FrameSourceError.notStreaming }
        guard pendingStill == nil else { throw FrameSourceError.stillUnavailable }

        return try await withCheckedThrowingContinuation { continuation in
            pendingStill = continuation
            stillTimeout = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard let self, let pending = self.pendingStill else { return }
                self.pendingStill = nil
                pending.resume(throwing: FrameSourceError.stillUnavailable)
            }
        }
    }

    // MARK: - Setup

    private func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    private func configureSession() async -> Bool {
        let position = position
        let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: position
        ) ?? AVCaptureDevice.default(for: .video)

        guard let device, let input = try? AVCaptureDeviceInput(device: device) else {
            state = .failed("No usable camera on this device.")
            return false
        }

        // Keep the preview and the delivered buffers upright as the phone turns.
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture,
            options: [.new]
        ) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            Task { @MainActor in self?.applyRotation(angle) }
        }
        let initialAngle = coordinator.videoRotationAngleForHorizonLevelCapture

        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: false); return }
                self.session.beginConfiguration()
                self.session.sessionPreset = .hd1280x720

                for existing in self.session.inputs { self.session.removeInput(existing) }
                for existing in self.session.outputs { self.session.removeOutput(existing) }

                guard self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    Task { @MainActor in self.state = .failed("The camera is already in use.") }
                    continuation.resume(returning: false)
                    return
                }
                self.session.addInput(input)

                self.output.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                self.output.alwaysDiscardsLateVideoFrames = true
                self.output.setSampleBufferDelegate(self, queue: self.queue)
                if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }

                if let connection = self.output.connection(with: .video) {
                    if connection.isVideoRotationAngleSupported(initialAngle) {
                        connection.videoRotationAngle = initialAngle
                    }
                    if connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = position == .front
                    }
                }

                self.session.commitConfiguration()
                continuation.resume(returning: true)
            }
        }
    }

    private func applyRotation(_ angle: CGFloat) {
        queue.async { [output] in
            guard let connection = output.connection(with: .video),
                  connection.isVideoRotationAngleSupported(angle) else { return }
            connection.videoRotationAngle = angle
        }
    }
}

extension DeviceCameraFrameSource: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        SampleBufferPreviewView.markForImmediateDisplay(sampleBuffer)
        let size = CGSize(
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer)
        )
        Task { @MainActor [weak self] in
            self?.receive(buffer: buffer, sampleBuffer: sampleBuffer, size: size)
        }
    }

    @MainActor
    private func receive(buffer: CVPixelBuffer, sampleBuffer: CMSampleBuffer, size: CGSize) {
        previewView?.enqueue(sampleBuffer)

        if displaySize != size { displaySize = size }
        if !state.isStreaming { state = .streaming }

        let now = CACurrentMediaTime()
        let frame = VideoFrame(
            image: .pixelBuffer(buffer),
            size: size,
            orientation: .up,
            capturedAt: now
        )

        if let pending = pendingStill {
            pendingStill = nil
            stillTimeout?.cancel()
            stillTimeout = nil
            // Copy out of the rotating capture pool before handing the still on.
            if let cgImage = frame.makeCGImage() {
                pending.resume(returning: VideoFrame(
                    image: .cgImage(cgImage),
                    size: size,
                    orientation: .up,
                    capturedAt: now
                ))
            } else {
                pending.resume(throwing: FrameSourceError.stillUnavailable)
            }
        }

        guard now - lastDelivered >= 1.0 / max(1, samplingRate) else { return }
        lastDelivered = now
        onFrame?(frame)
    }
}

/// Renders capture-session sample buffers, letterboxed like the FIELD ONE view.
final class SampleBufferPreviewView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    private var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sampleBuffer)
    }

    func flush() {
        displayLayer.flushAndRemoveImage()
    }

    /// Capture buffers carry no timebase, so ask the renderer to show them at once.
    nonisolated static func markForImmediateDisplay(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: true
        ) else { return }
        let raw = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0),
            to: CFMutableDictionary.self
        )
        CFDictionarySetValue(
            raw,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}
