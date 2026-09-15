import CoreGraphics
import Foundation
import SwiftUI
import UIKit

/// Drives the live inspection screen: owns the video source, feeds frames to
/// the detector, and turns a capture press into a saved, annotated still.
@MainActor
@Observable
final class LiveViewModel {
    private(set) var sourceKind: FrameSourceKind
    private(set) var state: SourceState = .idle
    private(set) var result = InferenceResult.empty
    private(set) var stats = InferenceStats()
    private(set) var lastCapture: CaptureRecord?
    private(set) var detectorError: String?
    private(set) var frameSize: CGSize?

    /// Non-nil while a capture is in flight; drives the progress overlay.
    private(set) var captureStage: CaptureStage?
    /// Set when a capture finishes, to present it for review.
    var reviewCapture: CaptureRecord?

    var isCapturing: Bool { captureStage != nil }

    /// Set when the operator pauses inference but keeps the video running.
    var isInferenceEnabled = true {
        didSet { if !isInferenceEnabled { result = .empty; stats.reset() } }
    }

    var banner: BannerMessage?

    private(set) var source: FrameSource
    private var detector: Detector?
    private var detectorModelID: UUID?
    private var detectorSettings: DetectionSettings?
    private var isInferring = false
    private var captureTask: Task<Void, Never>?

    private let settings: AppSettings
    private let modelStore: ModelStore
    private let captureStore: CaptureStore

    struct BannerMessage: Identifiable, Equatable {
        let id = UUID()
        var kind: CarbonNotificationKind
        var title: String
        var message: String?
    }

    enum CaptureStage: Equatable {
        case camera(CaptureProgress)
        case analysing(width: Int, height: Int)
        case saving

        var title: String {
            switch self {
            case .camera(let progress): progress.title
            case .analysing(let width, let height): "Running model on \(width) x \(height)"
            case .saving: "Saving"
            }
        }

        var fraction: Double? {
            if case .camera(let progress) = self { return progress.fraction }
            return nil
        }
    }

    init(settings: AppSettings, modelStore: ModelStore, captureStore: CaptureStore) {
        self.settings = settings
        self.modelStore = modelStore
        self.captureStore = captureStore
        self.sourceKind = settings.preferredSource
        self.source = LiveViewModel.makeSource(kind: settings.preferredSource, settings: settings)
        wire(source)
    }

    /// What the shutter will produce right now, for its label.
    var shutterMode: ShutterMode {
        guard state.isStreaming else { return .unavailable }
        return source.capturesCameraPhotos ? .cameraPhoto : .liveFrame
    }

    enum ShutterMode {
        case cameraPhoto, liveFrame, unavailable
    }

    /// Why a FIELD ONE shutter is saving live frames instead of camera photos.
    var photoFallbackReason: String? {
        (source as? FieldOneFrameSource)?.photoUnavailableReason
    }

    // MARK: - Source lifecycle

    private static func makeSource(kind: FrameSourceKind, settings: AppSettings) -> FrameSource {
        switch kind {
        case .fieldOne:
            let source = FieldOneFrameSource()
            source.joinWiFiAutomatically = settings.joinWiFiAutomatically
            source.preferredHost = settings.preferredHost
            source.samplingRate = settings.detection.samplingRate
            return source
        case .deviceCamera:
            let source = DeviceCameraFrameSource()
            source.samplingRate = settings.detection.samplingRate
            return source
        }
    }

    private func wire(_ source: FrameSource) {
        source.onStateChange = { [weak self] state in
            guard let self else { return }
            self.state = state
            if case .failed(let message) = state {
                self.banner = BannerMessage(kind: .error, title: "Video source failed", message: message)
            }
        }
        source.onFrame = { [weak self] frame in
            self?.handle(frame)
        }
    }

    func start() async {
        detectorError = nil
        await source.start()
    }

    func stop() {
        captureTask?.cancel()
        captureTask = nil
        source.stop()
        stats.reset()
        result = .empty
    }

    func switchSource(to kind: FrameSourceKind) async {
        guard kind != sourceKind, !isCapturing else { return }
        source.stop()
        sourceKind = kind
        settings.preferredSource = kind
        source = LiveViewModel.makeSource(kind: kind, settings: settings)
        wire(source)
        result = .empty
        stats.reset()
        frameSize = nil
        await start()
    }

    func refreshSourceConfiguration() {
        source.samplingRate = settings.detection.samplingRate
        if let fieldOne = source as? FieldOneFrameSource {
            fieldOne.joinWiFiAutomatically = settings.joinWiFiAutomatically
            fieldOne.preferredHost = settings.preferredHost
        }
    }

    // MARK: - Live inference

    private func handle(_ frame: VideoFrame) {
        frameSize = frame.displaySize
        // The camera photo gets the detector to itself while it is captured.
        guard isInferenceEnabled, !isInferring, !isCapturing else { return }
        guard let detector = currentDetector() else { return }

        isInferring = true
        let settings = self.settings.detection
        Task { [weak self] in
            defer { Task { @MainActor in self?.isInferring = false } }
            do {
                let output = try await detector.detect(frame, settings: settings)
                await MainActor.run {
                    guard let self, !self.isCapturing else { return }
                    self.result = output
                    self.stats.record(milliseconds: output.inferenceMilliseconds, at: output.completedAt)
                    self.detectorError = nil
                }
            } catch {
                await MainActor.run { self?.detectorError = error.localizedDescription }
            }
        }
    }

    /// Builds or reuses the detector for the selected model and settings.
    private func currentDetector() -> Detector? {
        guard let model = modelStore.selectedModel else { return nil }
        let current = settings.detection

        if let detector, detectorModelID == model.id,
           detectorSettings?.computeUnits == current.computeUnits {
            return detector
        }

        do {
            let built = try Detector(
                stored: model,
                compiledURL: modelStore.compiledModelURL(for: model.id),
                settings: current
            )
            detector = built
            detectorModelID = model.id
            detectorSettings = current
            detectorError = nil
            return built
        } catch {
            detector = nil
            detectorModelID = nil
            detectorError = error.localizedDescription
            return nil
        }
    }

    /// Discards the built detector so the next frame rebuilds it.
    func invalidateDetector() {
        detector = nil
        detectorModelID = nil
        detectorSettings = nil
        result = .empty
        stats.reset()
    }

    // MARK: - Capture

    func capture() {
        guard !isCapturing, state.isStreaming else { return }
        captureStage = .camera(.takingPhoto)
        captureTask = Task { [weak self] in
            await self?.performCapture()
            self?.captureTask = nil
        }
    }

    /// Takes the best still the source offers - a camera photo on FIELD ONE -
    /// runs the model over exactly those pixels at full resolution, and saves
    /// the still with its boxes burnt in. Never retries the shutter on failure.
    private func performCapture() async {
        defer { captureStage = nil }

        let still: CapturedStill
        do {
            still = try await source.captureStill { [weak self] progress in
                self?.captureStage = .camera(progress)
            }
        } catch is CancellationError {
            return
        } catch {
            banner = BannerMessage(kind: .error, title: "Capture failed", message: error.localizedDescription)
            return
        }

        guard let pixels = still.frame.makeCGImage() else {
            banner = BannerMessage(kind: .error, title: "Capture failed", message: CaptureError.noFrame.localizedDescription)
            return
        }

        var detections: [Detection] = []
        var inferenceMilliseconds: Double?
        var modelName = modelStore.selectedModel?.displayName ?? "No model"
        var inferenceProblem: String?

        if !isInferenceEnabled {
            modelName = "Inference paused"
        } else if let detector = currentDetector() {
            captureStage = .analysing(width: pixels.width, height: pixels.height)
            do {
                let output = try await detector.detect(still.frame, settings: settings.detection)
                detections = output.detections
                inferenceMilliseconds = output.inferenceMilliseconds
            } catch {
                inferenceProblem = error.localizedDescription
            }
        } else if modelStore.selectedModel == nil {
            inferenceProblem = "No model is selected, so the still was saved without boxes."
        } else {
            inferenceProblem = detectorError
        }

        captureStage = .saving
        let annotation = FrameCompositor.Annotation(
            detections: detections,
            modelName: modelName,
            sourceName: sourceLabel(for: still, pixels: pixels),
            capturedAt: Date(),
            burnInMetadata: settings.burnInMetadata,
            provenanceNote: nil
        )

        do {
            let annotated = await Task.detached(priority: .userInitiated) {
                FrameCompositor.annotate(pixels, with: annotation)
            }.value

            let record = try await captureStore.save(
                still: still,
                annotated: annotated,
                detections: detections,
                sourceKind: sourceKind,
                modelName: modelName,
                modelID: modelStore.selectedModel?.id,
                inferenceMilliseconds: inferenceMilliseconds
            )
            lastCapture = record
            reviewCapture = record

            if settings.hapticOnCapture {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            if let inferenceProblem {
                banner = BannerMessage(kind: .warning, title: "Saved without boxes", message: inferenceProblem)
            } else if still.provenance == .livePreviewFrame, sourceKind == .fieldOne,
                      let reason = photoFallbackReason {
                banner = BannerMessage(kind: .warning, title: "Saved a live frame", message: reason)
            }
        } catch {
            banner = BannerMessage(kind: .error, title: "Could not save the capture", message: error.localizedDescription)
        }
    }

    private func sourceLabel(for still: CapturedStill, pixels: CGImage) -> String {
        let size = "\(pixels.width)x\(pixels.height)"
        switch (sourceKind, still.provenance) {
        case (.fieldOne, .cameraPhoto): return "FIELD ONE camera photo \(size)"
        case (.fieldOne, .recoveredRecordingFrame): return "FIELD ONE recovered recording frame \(size)"
        case (.fieldOne, _): return "FIELD ONE live frame \(size)"
        case (.deviceCamera, _): return "iPhone camera \(size)"
        }
    }
}
