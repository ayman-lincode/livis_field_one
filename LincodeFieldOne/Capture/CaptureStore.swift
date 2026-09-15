import Foundation
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

/// Saves captured frames into the app container and lists them back.
///
/// Each capture is three files: the annotated JPEG with boxes burnt in, the
/// original image, and a JSON record. A FIELD ONE camera photo's original is
/// the camera's own JPEG bytes, written unmodified. Full camera photos run to
/// 12 MP, so every on-screen image is a cached downsample, never a full decode.
@MainActor
@Observable
final class CaptureStore {
    private(set) var captures: [CaptureRecord] = []
    var lastError: String?

    private let root: URL
    @ObservationIgnored private let imageCache = NSCache<NSString, UIImage>()

    nonisolated static let thumbnailPixels = 360
    nonisolated static let displayPixels = 2400

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = documents.appendingPathComponent("Captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        imageCache.totalCostLimit = 160 * 1024 * 1024
        reload()
    }

    func annotatedURL(for id: UUID) -> URL {
        root.appendingPathComponent("\(id.uuidString)-annotated.jpg")
    }

    func originalURL(for id: UUID) -> URL {
        root.appendingPathComponent("\(id.uuidString)-original.jpg")
    }

    func recordURL(for id: UUID) -> URL {
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

    /// Writes a capture to disk. Encoding a 12 MP JPEG takes a noticeable
    /// fraction of a second, so the files are produced off the main actor.
    @discardableResult
    func save(
        still: CapturedStill,
        annotated: UIImage,
        detections: [Detection],
        sourceKind: FrameSourceKind,
        modelName: String,
        modelID: UUID?,
        inferenceMilliseconds: Double?
    ) async throws -> CaptureRecord {
        guard let pixels = still.frame.makeCGImage() else { throw CaptureError.noFrame }

        let id = UUID()
        let record = CaptureRecord(
            id: id,
            capturedAt: Date(),
            sourceKind: sourceKind,
            modelName: modelName,
            modelID: modelID,
            frameWidth: pixels.width,
            frameHeight: pixels.height,
            detections: detections.map(CaptureRecord.StoredDetection.init),
            provenance: still.provenance,
            camera: still.camera,
            inferenceMilliseconds: inferenceMilliseconds
        )

        let annotatedURL = annotatedURL(for: id)
        let originalURL = originalURL(for: id)
        let recordURL = recordURL(for: id)
        let encodedJPEG = still.encodedJPEG

        try await Task.detached(priority: .userInitiated) {
            guard let annotatedData = annotated.jpegData(compressionQuality: 0.9) else {
                throw CaptureError.encodingFailed
            }
            try annotatedData.write(to: annotatedURL, options: .atomic)

            if let encodedJPEG {
                // Evidence: the camera's bytes exactly as delivered.
                try encodedJPEG.write(to: originalURL, options: .atomic)
            } else {
                try Self.writeJPEG(pixels, to: originalURL, quality: 0.92)
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(record).write(to: recordURL, options: .atomic)
        }.value

        captures.insert(record, at: 0)
        return record
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: annotatedURL(for: id))
        try? FileManager.default.removeItem(at: originalURL(for: id))
        try? FileManager.default.removeItem(at: recordURL(for: id))
        for annotated in [true, false] {
            for pixels in [Self.thumbnailPixels, Self.displayPixels] {
                imageCache.removeObject(forKey: cacheKey(id, annotated, pixels))
            }
        }
        captures.removeAll { $0.id == id }
    }

    func deleteAll() {
        for capture in captures { delete(capture.id) }
    }

    /// A small image for grids and the live view's last-capture button.
    func thumbnail(for id: UUID, annotated: Bool = true) -> UIImage? {
        image(for: id, annotated: annotated, maxPixelSize: Self.thumbnailPixels)
    }

    /// A screen-sized image. Never the full-resolution decode.
    func image(for id: UUID, annotated: Bool = true, maxPixelSize: Int = CaptureStore.displayPixels) -> UIImage? {
        let key = cacheKey(id, annotated, maxPixelSize)
        if let cached = imageCache.object(forKey: key) { return cached }
        let url = annotated ? annotatedURL(for: id) : originalURL(for: id)
        guard let cgImage = StillImageDecoder.downsampledImage(at: url, maxPixelSize: maxPixelSize) else {
            return nil
        }
        let image = UIImage(cgImage: cgImage)
        imageCache.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }

    private func cacheKey(_ id: UUID, _ annotated: Bool, _ pixels: Int) -> NSString {
        "\(id.uuidString)-\(annotated ? "a" : "o")-\(pixels)" as NSString
    }

    /// Adds a capture to the operator's photo library. Asks for add-only
    /// access, the narrowest permission that works.
    func exportToPhotoLibrary(_ id: UUID, annotated: Bool = true) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw CaptureError.photoLibraryDenied
        }
        let url = annotated ? annotatedURL(for: id) : originalURL(for: id)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)
        }
    }

    /// Writes every capture, its original and its record into one folder.
    func exportBundle() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FIELD-ONE-captures-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        for capture in captures {
            let stamp = formatter.string(from: capture.capturedAt).replacingOccurrences(of: ":", with: "-")
            let name = "\(stamp)-\(capture.id.uuidString.prefix(8))"
            try? FileManager.default.copyItem(
                at: annotatedURL(for: capture.id),
                to: folder.appendingPathComponent("\(name)-annotated.jpg")
            )
            try? FileManager.default.copyItem(
                at: originalURL(for: capture.id),
                to: folder.appendingPathComponent("\(name)-original.jpg")
            )
            try? FileManager.default.copyItem(
                at: recordURL(for: capture.id),
                to: folder.appendingPathComponent("\(name).json")
            )
        }
        return folder
    }

    nonisolated private static func writeJPEG(_ image: CGImage, to url: URL, quality: Double) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw CaptureError.encodingFailed }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.encodingFailed }
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
