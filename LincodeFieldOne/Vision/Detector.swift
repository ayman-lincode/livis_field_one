import QuartzCore
import CoreImage
import CoreML
import Foundation
import Vision

/// How the frame is fitted to the model's square input.
enum InputFitting: String, CaseIterable, Codable, Identifiable {
    /// Stretch the whole frame to the input. What Ultralytics exports expect.
    case stretch
    /// Letterbox the whole frame, preserving aspect ratio.
    case letterbox
    /// Crop to a centred square, then scale. Vision's own default.
    case centreCrop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stretch: "Stretch"
        case .letterbox: "Letterbox"
        case .centreCrop: "Centre crop"
        }
    }

    var caption: String {
        switch self {
        case .stretch: "Whole frame, aspect ratio distorted. Matches most YOLO exports."
        case .letterbox: "Whole frame, padded to square. Matches letterboxed training."
        case .centreCrop: "Centre square only. Edges of the frame are not inspected."
        }
    }

    var visionOption: VNImageCropAndScaleOption {
        switch self {
        case .stretch: .scaleFill
        case .letterbox: .scaleFit
        case .centreCrop: .centerCrop
        }
    }
}

/// Tunables the operator can change without re-importing a model.
struct DetectionSettings: Codable, Equatable {
    var confidenceThreshold: Double = 0.35
    var iouThreshold: Double = 0.45
    var maxDetections: Int = 50
    var fitting: InputFitting = .stretch
    var computeUnits: ComputeUnitsPreference = .all
    /// Frames per second offered to the detector. Frames arriving while a
    /// previous one is still running are dropped, never queued.
    var samplingRate: Double = 10

    enum ComputeUnitsPreference: String, CaseIterable, Codable, Identifiable {
        case all, neuralEngine, gpu, cpu

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "Automatic"
            case .neuralEngine: "Neural Engine"
            case .gpu: "GPU"
            case .cpu: "CPU only"
            }
        }

        var mlComputeUnits: MLComputeUnits {
            switch self {
            case .all: .all
            case .neuralEngine: .cpuAndNeuralEngine
            case .gpu: .cpuAndGPU
            case .cpu: .cpuOnly
            }
        }
    }
}

/// Runs one model over frames and returns normalised detections.
///
/// Vision handles resizing and, for models that carry a detector head it
/// recognises, decoding too. For raw tensor exports the app decodes the output
/// itself and undoes whatever fitting Vision applied, so boxes land on the
/// right pixels of the original frame rather than of the model's square input.
actor Detector {
    let modelID: UUID
    private let stored: StoredModel
    private let vnModel: VNCoreMLModel
    private var cachedLayout: DetectionDecoder.Layout?
    private(set) var resolvedTask: ModelTask

    init(stored: StoredModel, compiledURL: URL, settings: DetectionSettings) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = settings.computeUnits.mlComputeUnits

        let mlModel: MLModel
        do {
            mlModel = try MLModel(contentsOf: compiledURL, configuration: configuration)
        } catch {
            throw ModelError.loadFailed(error.localizedDescription)
        }

        do {
            vnModel = try VNCoreMLModel(for: mlModel)
        } catch {
            throw ModelError.loadFailed(error.localizedDescription)
        }

        self.stored = stored
        self.modelID = stored.id
        self.resolvedTask = stored.summary.task
    }

    /// The layout the decoder settled on, for display in the model inspector.
    var layoutDescription: String? { cachedLayout?.description }

    func detect(_ frame: VideoFrame, settings: DetectionSettings) throws -> InferenceResult {
        let request = VNCoreMLRequest(model: vnModel)
        request.imageCropAndScaleOption = settings.fitting.visionOption

        let handler: VNImageRequestHandler
        switch frame.image {
        case .pixelBuffer(let buffer):
            handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: frame.orientation)
        case .cgImage(let image):
            handler = VNImageRequestHandler(cgImage: image, orientation: frame.orientation)
        }

        let started = CACurrentMediaTime()
        try handler.perform([request])
        let elapsed = (CACurrentMediaTime() - started) * 1000

        let detections = decode(request.results ?? [], frame: frame, settings: settings)
        return InferenceResult(
            detections: detections,
            frameSize: frame.displaySize,
            inferenceMilliseconds: elapsed,
            completedAt: CACurrentMediaTime()
        )
    }

    // MARK: - Result decoding

    private func decode(
        _ results: [VNObservation],
        frame: VideoFrame,
        settings: DetectionSettings
    ) -> [Detection] {
        // Preferred path: Vision already understood the detector head.
        let recognised = results.compactMap { $0 as? VNRecognizedObjectObservation }
        if !recognised.isEmpty {
            resolvedTask = .visionDetector
            return recognised
                .filter { ($0.labels.first?.confidence ?? 0) >= Float(settings.confidenceThreshold) }
                .prefix(settings.maxDetections)
                .map { observation in
                    let identifier = observation.labels.first?.identifier ?? ""
                    let index = classIndex(for: identifier)
                    return Detection(
                        classIndex: index,
                        label: identifier.isEmpty ? stored.labels.name(for: index) : identifier,
                        confidence: observation.labels.first?.confidence ?? 0,
                        rect: flipVertically(observation.boundingBox)
                    )
                }
        }

        let features = results.compactMap { $0 as? VNCoreMLFeatureValueObservation }
        guard !features.isEmpty else { return [] }

        let options = DetectionDecoder.Options(
            confidenceThreshold: Float(settings.confidenceThreshold),
            iouThreshold: Float(settings.iouThreshold),
            maxDetections: settings.maxDetections,
            inputSize: stored.summary.inputSize
        )

        // A two-tensor NMS pipeline.
        if let confidence = features.first(where: { $0.featureName == "confidence" })?
            .featureValue.multiArrayValue,
           let coordinates = features.first(where: { $0.featureName == "coordinates" })?
            .featureValue.multiArrayValue {
            resolvedTask = .nmsPipeline
            let raw = DetectionDecoder.decodePipeline(
                confidence: confidence,
                coordinates: coordinates,
                labels: stored.labels,
                options: options
            )
            return raw.map { rebase($0, frame: frame, fitting: settings.fitting) }
        }

        // A single raw tensor.
        guard let array = features
            .compactMap({ $0.featureValue.multiArrayValue })
            .max(by: { $0.count < $1.count }) else { return [] }

        let expected = stored.labels.origin == .placeholder ? nil : stored.labels.count
        let layout = cachedLayout ?? DetectionDecoder.layout(for: array, expectedClassCount: expected)
        guard let layout else { return [] }
        cachedLayout = layout
        resolvedTask = .rawTensor

        let raw = DetectionDecoder.decode(
            array, layout: layout, labels: stored.labels, options: options
        )
        return raw.map { rebase($0, frame: frame, fitting: settings.fitting) }
    }

    private func classIndex(for identifier: String) -> Int {
        if let index = stored.labels.names.firstIndex(of: identifier) { return index }
        if let index = Int(identifier) { return index }
        // Unknown identifier: pick a stable colour slot from the name itself.
        return abs(identifier.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF })
    }

    /// Vision's y axis runs upward; the overlay and the compositor use the
    /// image convention, so flip it once here.
    private func flipVertically(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: 1 - rect.maxY,
            width: rect.width,
            height: rect.height
        ).clampedToUnitSquare()
    }

    /// Undoes the crop-and-scale Vision applied, so a box expressed in the
    /// model's square input space lands on the right part of the whole frame.
    private func rebase(_ detection: Detection, frame: VideoFrame, fitting: InputFitting) -> Detection {
        let size = frame.displaySize
        guard size.width > 0, size.height > 0, fitting != .stretch else { return detection }

        let aspect = size.width / size.height
        var scaleX: CGFloat = 1, scaleY: CGFloat = 1
        var offsetX: CGFloat = 0, offsetY: CGFloat = 0

        switch fitting {
        case .stretch:
            break
        case .centreCrop:
            // Only a centred square of the frame reached the model.
            if aspect > 1 {
                scaleX = 1 / aspect
                offsetX = (1 - scaleX) / 2
            } else {
                scaleY = aspect
                offsetY = (1 - scaleY) / 2
            }
        case .letterbox:
            // The whole frame reached the model, inset by padding bars.
            if aspect > 1 {
                scaleY = aspect
                offsetY = -(scaleY - 1) / 2
            } else {
                scaleX = 1 / aspect
                offsetX = -(scaleX - 1) / 2
            }
        }

        let rect = CGRect(
            x: offsetX + detection.rect.minX * scaleX,
            y: offsetY + detection.rect.minY * scaleY,
            width: detection.rect.width * scaleX,
            height: detection.rect.height * scaleY
        ).clampedToUnitSquare()

        return Detection(
            id: detection.id,
            classIndex: detection.classIndex,
            label: detection.label,
            confidence: detection.confidence,
            rect: rect
        )
    }
}
