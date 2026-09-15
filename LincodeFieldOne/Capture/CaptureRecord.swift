import CoreGraphics
import Foundation

/// One saved inspection frame plus what the model said about it.
struct CaptureRecord: Identifiable, Codable, Equatable {
    let id: UUID
    var capturedAt: Date
    var sourceKind: FrameSourceKind
    var modelName: String
    var modelID: UUID?
    var frameWidth: Int
    var frameHeight: Int
    var detections: [StoredDetection]
    var note: String?
    var provenance: CaptureProvenance
    /// Present for FIELD ONE camera photos.
    var camera: CameraPhotoMetadata?
    /// How long the model took on this still, when it ran.
    var inferenceMilliseconds: Double?

    init(
        id: UUID,
        capturedAt: Date,
        sourceKind: FrameSourceKind,
        modelName: String,
        modelID: UUID?,
        frameWidth: Int,
        frameHeight: Int,
        detections: [StoredDetection],
        note: String? = nil,
        provenance: CaptureProvenance,
        camera: CameraPhotoMetadata? = nil,
        inferenceMilliseconds: Double? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.sourceKind = sourceKind
        self.modelName = modelName
        self.modelID = modelID
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.detections = detections
        self.note = note
        self.provenance = provenance
        self.camera = camera
        self.inferenceMilliseconds = inferenceMilliseconds
    }

    struct StoredDetection: Codable, Equatable {
        var label: String
        var classIndex: Int
        var confidence: Float
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(_ detection: Detection) {
            label = detection.label
            classIndex = detection.classIndex
            confidence = detection.confidence
            x = detection.rect.minX
            y = detection.rect.minY
            width = detection.rect.width
            height = detection.rect.height
        }

        var detection: Detection {
            Detection(
                classIndex: classIndex,
                label: label,
                confidence: confidence,
                rect: CGRect(x: x, y: y, width: width, height: height)
            )
        }
    }

    var frameSize: CGSize { CGSize(width: frameWidth, height: frameHeight) }

    var resolutionText: String { "\(frameWidth) x \(frameHeight)" }

    var summary: String {
        guard !detections.isEmpty else { return "No detections" }
        return Dictionary(grouping: detections, by: \.label)
            .map { "\($0.value.count) \($0.key)" }
            .sorted()
            .joined(separator: ", ")
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, capturedAt, sourceKind, modelName, modelID, frameWidth, frameHeight
        case detections, note, provenance, camera, inferenceMilliseconds
        /// Written by builds before camera photos existed.
        case isRecoveredRecordingFrame
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        sourceKind = try container.decode(FrameSourceKind.self, forKey: .sourceKind)
        modelName = try container.decode(String.self, forKey: .modelName)
        modelID = try container.decodeIfPresent(UUID.self, forKey: .modelID)
        frameWidth = try container.decode(Int.self, forKey: .frameWidth)
        frameHeight = try container.decode(Int.self, forKey: .frameHeight)
        detections = try container.decode([StoredDetection].self, forKey: .detections)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        camera = try container.decodeIfPresent(CameraPhotoMetadata.self, forKey: .camera)
        inferenceMilliseconds = try container.decodeIfPresent(Double.self, forKey: .inferenceMilliseconds)

        if let provenance = try container.decodeIfPresent(CaptureProvenance.self, forKey: .provenance) {
            self.provenance = provenance
        } else {
            let recovered = try container.decodeIfPresent(Bool.self, forKey: .isRecoveredRecordingFrame) ?? false
            provenance = recovered ? .recoveredRecordingFrame : .livePreviewFrame
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encode(sourceKind, forKey: .sourceKind)
        try container.encode(modelName, forKey: .modelName)
        try container.encodeIfPresent(modelID, forKey: .modelID)
        try container.encode(frameWidth, forKey: .frameWidth)
        try container.encode(frameHeight, forKey: .frameHeight)
        try container.encode(detections, forKey: .detections)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encode(provenance, forKey: .provenance)
        try container.encodeIfPresent(camera, forKey: .camera)
        try container.encodeIfPresent(inferenceMilliseconds, forKey: .inferenceMilliseconds)
    }
}
