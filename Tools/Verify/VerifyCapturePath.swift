import CoreGraphics
import CoreML
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Checks the camera-photo path: JPEG decode, full-resolution inference with
/// the app's own `Detector`, and the capture record format.
@MainActor
enum CapturePathChecks {
    static func check(_ condition: Bool, _ description: String, _ detail: String = "") {
        Verify.check(condition, description, detail)
    }

    static func run() async {
        print("\n== Camera JPEG decoding ==")
        // Same size the SDK vendor trace reported for a FIELD ONE photo.
        let width = 4216, height = 2376
        guard let upright = makeScene(width: width, height: height),
              let plainJPEG = encodeJPEG(upright, orientation: nil),
              let rotatedJPEG = encodeJPEG(upright, orientation: .right) else {
            check(false, "build synthetic camera JPEGs", ""); return
        }

        let stored = StillImageDecoder.storedPixelSize(of: plainJPEG)
        check(stored == CGSize(width: width, height: height), "stored size read from JPEG header", "\(String(describing: stored))")

        let decoded = try? StillImageDecoder.uprightImage(from: plainJPEG)
        check(decoded?.width == width && decoded?.height == height,
              "full-resolution decode keeps every pixel", "\(decoded?.width ?? 0)x\(decoded?.height ?? 0)")

        let turned = try? StillImageDecoder.uprightImage(from: rotatedJPEG)
        check(turned?.width == height && turned?.height == width,
              "EXIF orientation applied, so boxes map onto what a viewer shows",
              "\(turned?.width ?? 0)x\(turned?.height ?? 0)")

        let garbage = (try? StillImageDecoder.uprightImage(from: Data("not a jpeg".utf8))) == nil
        check(garbage, "undecodable bytes throw instead of returning an empty image")

        print("\n== Model on a full-resolution still ==")
        let packageURL = URL(fileURLWithPath: "../SampleModel/QuadrantSmokeTest.mlpackage")
        guard let compiled = try? await MLModel.compileModel(at: packageURL),
              let mlModel = try? MLModel(contentsOf: compiled),
              let decoded else {
            check(false, "prepare smoke-test model", ""); return
        }

        let stored_ = StoredModel(
            id: UUID(),
            displayName: "QuadrantSmokeTest",
            originalFilename: "QuadrantSmokeTest.mlpackage",
            importedAt: Date(),
            byteSize: 0,
            labels: ModelStore.labels(from: mlModel, expectedCount: 2),
            summary: ModelStore.summarise(mlModel)
        )
        var settings = DetectionSettings()
        settings.confidenceThreshold = 0.5

        guard let detector = try? Detector(stored: stored_, compiledURL: compiled, settings: settings) else {
            check(false, "build the app's Detector", ""); return
        }
        let frame = VideoFrame(
            image: .cgImage(decoded),
            size: CGSize(width: decoded.width, height: decoded.height),
            orientation: .up,
            capturedAt: 0
        )

        guard let stretched = try? await detector.detect(frame, settings: settings) else {
            check(false, "Detector runs on a 4216x2376 still", ""); return
        }
        check(true, "Detector runs on a \(width)x\(height) still in \(Int(stretched.inferenceMilliseconds)) ms")
        check(stretched.frameSize == CGSize(width: width, height: height),
              "result is reported against the full still", "\(stretched.frameSize)")
        let bright = stretched.detections.filter { $0.label == "bright" }
        check(bright.count == 1, "the lit quadrant is found", "got \(bright.count)")
        if let box = bright.first {
            check(abs(box.rect.midX - 0.25) < 0.02 && abs(box.rect.midY - 0.25) < 0.02,
                  "box sits on the lit top-left quadrant of the photo", "\(box.rect)")
        }

        // Letterboxing pads the wide still into the square input; the decoder
        // must undo that so the box still lands on the lit quadrant.
        var letterbox = settings
        letterbox.fitting = .letterbox
        if let padded = try? await detector.detect(frame, settings: letterbox),
           let box = padded.detections.filter({ $0.label == "bright" }).max(by: { $0.confidence < $1.confidence }) {
            check(box.rect.minX < 0.5 && box.rect.minY < 0.5,
                  "letterbox fitting maps the box back into the photo's top-left", "\(box.rect)")
        } else {
            check(false, "letterbox fitting produced a bright box")
        }

        print("\n== Capture records ==")
        let legacy = """
        {"id":"\(UUID().uuidString)","capturedAt":"2026-09-10T10:00:00Z","sourceKind":"fieldOne",
         "modelName":"m","frameWidth":1280,"frameHeight":720,"detections":[],
         "isRecoveredRecordingFrame":false}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = try? decoder.decode(CaptureRecord.self, from: Data(legacy.utf8))
        check(old?.provenance == .livePreviewFrame, "captures saved by the previous build still load as live frames",
              "\(String(describing: old?.provenance))")

        let record = CaptureRecord(
            id: UUID(), capturedAt: Date(), sourceKind: .fieldOne, modelName: "QuadrantSmokeTest",
            modelID: stored_.id, frameWidth: width, frameHeight: height,
            detections: stretched.detections.map(CaptureRecord.StoredDetection.init),
            provenance: .cameraPhoto,
            camera: CameraPhotoMetadata(
                handle: 0x106, filename: "IMG_0001.JPG", byteCount: plainJPEG.count,
                width: width, height: height, latencyMs: 3890, deviceCapturedAt: nil
            ),
            inferenceMilliseconds: stretched.inferenceMilliseconds
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let roundTrip = (try? encoder.encode(record)).flatMap { try? decoder.decode(CaptureRecord.self, from: $0) }
        check(roundTrip?.provenance == .cameraPhoto && roundTrip?.camera?.handle == 0x106,
              "camera photo provenance and metadata survive a save and reload")
        check(record.camera?.megapixelsText == "10.0 MP", "megapixel label", record.camera?.megapixelsText ?? "-")

        if let directory = ProcessInfo.processInfo.environment["EMIT_SAMPLE_CAPTURE"] {
            emitSample(record: record, jpeg: plainJPEG, to: URL(fileURLWithPath: directory))
        }
    }

    /// Writes a capture the app can load, for screenshotting the review screen.
    static func emitSample(record: CaptureRecord, jpeg: Data, to directory: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = directory.appendingPathComponent(record.id.uuidString)
        try? jpeg.write(to: URL(fileURLWithPath: base.path + "-original.jpg"))
        try? jpeg.write(to: URL(fileURLWithPath: base.path + "-annotated.jpg"))
        try? encoder.encode(record).write(to: URL(fileURLWithPath: base.path + ".json"))
        print("  wrote sample capture to \(directory.path)")
    }

    /// A dim workbench with a lamp-lit top-left quadrant.
    static func makeScene(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0.05, green: 0.05, blue: 0.06, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // CoreGraphics origin is bottom-left, so the top-left quadrant is high y.
        context.setFillColor(CGColor(srgbRed: 1, green: 0.98, blue: 0.94, alpha: 1))
        context.fill(CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2))
        context.setFillColor(CGColor(srgbRed: 0.22, green: 0.22, blue: 0.24, alpha: 1))
        context.fill(CGRect(x: width * 6 / 10, y: height / 8, width: width / 4, height: height / 4))
        return context.makeImage()
    }

    static func encodeJPEG(_ image: CGImage, orientation: CGImagePropertyOrientation?) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation.rawValue }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
