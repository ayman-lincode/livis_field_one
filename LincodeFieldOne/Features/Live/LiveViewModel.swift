import CoreGraphics
import Foundation
import SwiftUI
import UIKit

/// Drives the live inspection screen: owns the video source, feeds frames to
/// the detector, and turns a capture press into a saved, annotated frame.
@MainActor
@Observable
final class LiveViewModel {
    private(set) var sourceKind: FrameSourceKind
    private(set) var state: SourceState = .idle
    private(set) var result = InferenceResult.empty
    private(set) var stats = InferenceStats()
    private(set) var isCapturing = false
    private(set) var lastCapture: CaptureRecord?
    private(set) var detectorError: String?
    private(set) var frameSize: CGSize?

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

    private let settings: AppSettings
    private let modelStore: ModelStore
    private let captureStore: CaptureStore

    struct BannerMessage: Identifiable, Equatable {
        let id = UUID()
        var kind: CarbonNotificationKind
        var title: String
        var message: String?
    }

    init(settings: AppSettings, modelStore: ModelStore, captureStore: CaptureStore) {
        self.settings = settings
        self.modelStore = modelStore
        self.captureStore = captureStore
        self.sourceKind = settings.preferredSource
        self.source = LiveViewModel.makeSource(
            kind: settings.preferredSource, settings: settings
        )
        wire(source)
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
                self.banner = BannerMessage(
                    kind: .error, title: "Video source failed", message: message
                )
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
        source.stop()
        stats.reset()
        result = .empty
    }

    func switchSource(to kind: FrameSourceKind) async {
        guard kind != sourceKind else { return }
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

    // MARK: - Inference

    private func handle(_ frame: VideoFrame) {
        frameSize = frame.displaySize
        guard isInferenceEnabled, !isInferring else { return }
        guard let detector = currentDetector() else { return }

        isInferring = true
        let settings = self.settings.detection
        Task { [weak self] in
            defer { Task { @MainActor in self?.isInferring = false } }
            do {
                let output = try await detector.detect(frame, settings: settings)
                await MainActor.run {
                    guard let self else { return }
                    self.result = output
                    self.stats.record(
                        milliseconds: output.inferenceMilliseconds, at: output.completedAt
                    )
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

        if let detector,
           detectorModelID == model.id,
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

    /// Takes a full-quality still, runs the model over exactly those pixels,
    /// and saves the frame with the boxes burnt in.
    func capture() async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }

        do {
            let still = try await source.captureStill()
            guard let image = still.makeCGImage() else { throw CaptureError.noFrame }

            var detections = result.detections
            var modelName = modelStore.selectedModel?.displayName ?? "No model"

            if isInferenceEnabled, let detector = currentDetector() {
                if let output = try? await detector.detect(still, settings: settings.detection) {
                    detections = output.detections
                }
            } else if !isInferenceEnabled {
                detections = []
                modelName = "Inference paused"
            }

            let annotated = FrameCompositor.annotate(image, with: .init(
                detections: detections,
                modelName: modelName,
                sourceName: sourceKind == .fieldOne
                    ? FieldOneProductName.live
                    : "iPhone camera",
                capturedAt: Date(),
                burnInMetadata: settings.burnInMetadata,
                provenanceNote: nil
            ))

            let record = try captureStore.save(
                frame: image,
                annotated: annotated,
                detections: detections,
                sourceKind: sourceKind,
                modelName: modelName,
                modelID: modelStore.selectedModel?.id
            )
            lastCapture = record

            if settings.hapticOnCapture {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            banner = BannerMessage(
                kind: .success,
                title: "Frame captured",
                message: detections.isEmpty
                    ? "Saved with no detections."
                    : "Saved with \(detections.count) box\(detections.count == 1 ? "" : "es") burnt in."
            )
        } catch {
            banner = BannerMessage(
                kind: .error, title: "Capture failed", message: error.localizedDescription
            )
        }
    }
}

/// Wording the SDK requires the host app to preserve, so a recovered recording
/// frame is never presented as a live shutter capture.
enum FieldOneProductName {
    static let live = "FIELD ONE live 1280x720"
    static let recovered = "FIELD ONE recovered recording frame"
}
