import Foundation
import Photos
import UIKit

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
    /// True when the pixels came from a closed camera recording rather than the
    /// live stream. The SDK requires this distinction to be preserved.
    var isRecoveredRecordingFrame: Bool

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

    var summary: String {
        guard !detections.isEmpty else { return "No detections" }
        let counts = Dictionary(grouping: detections, by: \.label)
            .map { "\($0.value.count) \($0.key)" }
            .sorted()
        return counts.joined(separator: ", ")
    }
}

/// Saves annotated frames into the app container and lists them back.
@MainActor
@Observable
final class CaptureStore {
    private(set) var captures: [CaptureRecord] = []
    var lastError: String?

    private let root: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = documents.appendingPathComponent("Captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    func annotatedURL(for id: UUID) -> URL {
        root.appendingPathComponent("\(id.uuidString)-annotated.jpg")
    }

    func originalURL(for id: UUID) -> URL {
        root.appendingPathComponent("\(id.uuidString)-original.jpg")
    }

    private func recordURL(for id: UUID) -> URL {
        root.appendingPathComponent("\(id.uuidString).json")
    }

    func reload() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        )) ?? []
        captures = contents
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(CaptureRecord.self, from: data)
            }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    @discardableResult
    func save(
        frame: CGImage,
        annotated: UIImage,
        detections: [Detection],
        sourceKind: FrameSourceKind,
        modelName: String,
        modelID: UUID?,
        isRecoveredRecordingFrame: Bool = false,
        note: String? = nil
    ) throws -> CaptureRecord {
        let id = UUID()
        let record = CaptureRecord(
            id: id,
            capturedAt: Date(),
            sourceKind: sourceKind,
            modelName: modelName,
            modelID: modelID,
            frameWidth: frame.width,
            frameHeight: frame.height,
            detections: detections.map(CaptureRecord.StoredDetection.init),
            note: note,
            isRecoveredRecordingFrame: isRecoveredRecordingFrame
        )

        guard let annotatedData = annotated.jpegData(compressionQuality: 0.92) else {
            throw CaptureError.encodingFailed
        }
        try annotatedData.write(to: annotatedURL(for: id), options: .atomic)

        if let originalData = UIImage(cgImage: frame).jpegData(compressionQuality: 0.92) {
            try? originalData.write(to: originalURL(for: id), options: .atomic)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: recordURL(for: id), options: .atomic)

        captures.insert(record, at: 0)
        return record
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: annotatedURL(for: id))
        try? FileManager.default.removeItem(at: originalURL(for: id))
        try? FileManager.default.removeItem(at: recordURL(for: id))
        captures.removeAll { $0.id == id }
    }

    func deleteAll() {
        for capture in captures { delete(capture.id) }
    }

    func image(for id: UUID, annotated: Bool = true) -> UIImage? {
        UIImage(contentsOfFile: (annotated ? annotatedURL(for: id) : originalURL(for: id)).path)
    }

    /// Adds the annotated frame to the operator's photo library. Asks for
    /// add-only access, which is the narrowest permission that works.
    func exportToPhotoLibrary(_ id: UUID) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw CaptureError.photoLibraryDenied
        }
        let url = annotatedURL(for: id)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)
        }
    }

    /// Writes every capture and its sidecar into one folder for AirDrop or Files.
    func exportBundle() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FIELD-ONE-captures-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for capture in captures {
            let stamp = ISO8601DateFormatter().string(from: capture.capturedAt)
                .replacingOccurrences(of: ":", with: "-")
            let name = "\(stamp)-\(capture.id.uuidString.prefix(8))"
            try? FileManager.default.copyItem(
                at: annotatedURL(for: capture.id),
                to: folder.appendingPathComponent("\(name).jpg")
            )
            try? FileManager.default.copyItem(
                at: recordURL(for: capture.id),
                to: folder.appendingPathComponent("\(name).json")
            )
        }
        return folder
    }
}

enum CaptureError: LocalizedError {
    case encodingFailed
    case photoLibraryDenied
    case noFrame

    var errorDescription: String? {
        switch self {
        case .encodingFailed: "The captured frame could not be encoded."
        case .photoLibraryDenied: "Photo library access is off for this app."
        case .noFrame: "There was no frame to capture."
        }
    }
}
