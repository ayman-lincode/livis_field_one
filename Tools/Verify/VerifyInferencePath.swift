import AppKit
import CoreML
import Foundation

@main
struct Verify {
    static var failures = 0

    static func check(_ condition: Bool, _ description: String, _ detail: String = "") {
        if condition {
            print("  PASS  \(description)")
        } else {
            failures += 1
            print("  FAIL  \(description) \(detail)")
        }
    }

    static func main() async {
        print("== Label parsing ==")
        let ultralytics = LabelSet.parseModelMetadata("{0: 'person', 1: 'bicycle', 2: 'car'}")
        check(ultralytics == ["person", "bicycle", "car"], "Ultralytics dict metadata", "\(ultralytics ?? [])")

        let jsonArray = try? LabelSet.parse(data: Data(#"["a","b"]"#.utf8), sourceName: "l.json")
        check(jsonArray?.names == ["a", "b"], "JSON array label file")

        let jsonObject = try? LabelSet.parse(data: Data(#"{"1":"b","0":"a"}"#.utf8), sourceName: "l.json")
        check(jsonObject?.names == ["a", "b"], "JSON index-to-name label file")

        let text = try? LabelSet.parse(data: Data("# comment\nscratch\n dent \n\nrust\n".utf8), sourceName: "l.txt")
        check(text?.names == ["scratch", "dent", "rust"], "Newline label file", "\(text?.names ?? [])")

        let yaml = try? LabelSet.parse(
            data: Data("path: ../x\nnames:\n  0: scratch\n  1: dent\ntrain: y\n".utf8),
            sourceName: "data.yaml"
        )
        check(yaml?.names == ["scratch", "dent"], "Ultralytics data.yaml", "\(yaml?.names ?? [])")

        print("\n== Layout detection on synthetic tensors ==")
        // YOLOv8 COCO: [1, 84, 8400]
        if let v8 = try? MLMultiArray(shape: [1, 84, 8400], dataType: .float32),
           let layout = DetectionDecoder.layout(for: v8, expectedClassCount: 80) {
            check(layout.kind == .channelsFirst && layout.classCount == 80 && layout.anchorCount == 8400,
                  "YOLOv8 [1,84,8400] reads as channels-first, 80 classes", "\(layout)")
        } else { check(false, "YOLOv8 layout") }

        // YOLOv5 COCO: [1, 25200, 85]
        if let v5 = try? MLMultiArray(shape: [1, 25200, 85], dataType: .float32),
           let layout = DetectionDecoder.layout(for: v5, expectedClassCount: 80) {
            check(layout.kind == .anchorsFirstWithObjectness && layout.classCount == 80,
                  "YOLOv5 [1,25200,85] reads as objectness layout", "\(layout)")
        } else { check(false, "YOLOv5 layout") }

        // Pre-decoded boxes: [1, 20, 6]
        if let decoded = try? MLMultiArray(shape: [1, 20, 6], dataType: .float32),
           let layout = DetectionDecoder.layout(for: decoded, expectedClassCount: nil) {
            check(layout.kind == .decodedBoxes, "[1,20,6] reads as pre-decoded boxes", "\(layout)")
        } else { check(false, "Pre-decoded layout") }

        print("\n== Decode + NMS on a hand-built tensor ==")
        // Two overlapping boxes of the same class plus one distinct box.
        let anchors = 3, classes = 2, channels = 4 + classes
        guard let tensor = try? MLMultiArray(shape: [1, channels as NSNumber, anchors as NSNumber], dataType: .float32) else {
            check(false, "allocate tensor"); report(); return
        }
        func set(_ channel: Int, _ anchor: Int, _ value: Float) {
            tensor[[0, channel as NSNumber, anchor as NSNumber]] = NSNumber(value: value)
        }
        // anchor 0 and 1 overlap heavily, class 0; anchor 2 sits elsewhere, class 1.
        let rows: [(Float, Float, Float, Float, Float, Float)] = [
            (0.30, 0.30, 0.20, 0.20, 0.90, 0.01),
            (0.31, 0.31, 0.20, 0.20, 0.70, 0.01),
            (0.80, 0.80, 0.10, 0.10, 0.02, 0.85)
        ]
        for (anchor, row) in rows.enumerated() {
            set(0, anchor, row.0); set(1, anchor, row.1); set(2, anchor, row.2); set(3, anchor, row.3)
            set(4, anchor, row.4); set(5, anchor, row.5)
        }
        let labels = LabelSet(names: ["scratch", "dent"], origin: .file, sourceName: "t")
        guard let layout = DetectionDecoder.layout(for: tensor, expectedClassCount: 2) else {
            check(false, "layout for hand-built tensor"); report(); return
        }
        let options = DetectionDecoder.Options(
            confidenceThreshold: 0.35, iouThreshold: 0.45, maxDetections: 10,
            inputSize: CGSize(width: 640, height: 640)
        )
        let detections = DetectionDecoder.decode(tensor, layout: layout, labels: labels, options: options)
        check(detections.count == 2, "NMS collapses the overlapping pair", "got \(detections.count)")
        check(detections.first?.label == "scratch", "highest-scoring box kept first", "\(detections.first?.label ?? "-")")
        check(abs(detections.first!.confidence - 0.90) < 0.001, "confidence preserved")
        let expected = CGRect(x: 0.20, y: 0.20, width: 0.20, height: 0.20)
        let got = detections.first!.rect
        check(
            abs(got.minX - expected.minX) < 0.001 && abs(got.minY - expected.minY) < 0.001
                && abs(got.width - expected.width) < 0.001,
            "centre-form box converted to top-left form", "\(got)"
        )
        check(detections.contains { $0.label == "dent" }, "second class survives NMS")

        print("\n== Pixel-unit boxes are normalised ==")
        guard let pixels = try? MLMultiArray(shape: [1, 6, 1], dataType: .float32) else {
            check(false, "allocate"); report(); return
        }
        // 320,320 centre with 128x128 extent, in 640-pixel model units.
        let pixelRow: [Float] = [320, 320, 128, 128, 0.95, 0.0]
        for (channel, value) in pixelRow.enumerated() {
            pixels[[0, channel as NSNumber, 0]] = NSNumber(value: value)
        }
        let pixelLayout = DetectionDecoder.Layout(kind: .channelsFirst, anchorCount: 1, classCount: 2)
        let pixelDetections = DetectionDecoder.decode(pixels, layout: pixelLayout, labels: labels, options: options)
        check(pixelDetections.count == 1, "pixel-unit tensor decodes")
        if let rect = pixelDetections.first?.rect {
            check(
                abs(rect.minX - 0.4) < 0.002 && abs(rect.width - 0.2) < 0.002,
                "640-pixel box rescaled to 0...1", "\(rect)"
            )
        }

        print("\n== Real Core ML model ==")
        let packageURL = URL(fileURLWithPath: "../SampleModel/QuadrantSmokeTest.mlpackage")
        guard let compiled = try? await MLModel.compileModel(at: packageURL),
              let model = try? MLModel(contentsOf: compiled) else {
            check(false, "compile QuadrantSmokeTest.mlpackage"); report(); return
        }
        check(true, "compiled the .mlpackage the way the app does on import")

        let summary = ModelStore.summarise(model)
        check(summary.task == .rawTensor, "summarised as a raw-tensor detector", "\(summary.task)")
        check(summary.inputWidth == 640 && summary.inputHeight == 640, "input size read as 640x640", summary.inputSizeText)
        let modelLabels = ModelStore.labels(from: model, expectedCount: 2)
        check(modelLabels.names == ["bright", "dark"], "class names read from model metadata", "\(modelLabels.names)")
        check(modelLabels.origin == .model, "labels marked as coming from the model")

        // Top-left quadrant white, everything else black.
        guard let buffer = makeQuadrantImage() else { check(false, "build test image"); report(); return }
        let input = try! MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)])
        guard let output = try? await model.prediction(from: input),
              let predictions = output.featureValue(for: "predictions")?.multiArrayValue else {
            check(false, "run prediction"); report(); return
        }
        check(predictions.shape.map(\.intValue) == [1, 6, 4], "output shape [1,6,4]", "\(predictions.shape)")

        guard let realLayout = DetectionDecoder.layout(for: predictions, expectedClassCount: 2) else {
            check(false, "layout for real output"); report(); return
        }
        let realOptions = DetectionDecoder.Options(
            confidenceThreshold: 0.5, iouThreshold: 0.45, maxDetections: 10,
            inputSize: CGSize(width: 640, height: 640)
        )
        let real = DetectionDecoder.decode(
            predictions, layout: realLayout, labels: modelLabels, options: realOptions
        )
        let bright = real.filter { $0.label == "bright" }
        check(bright.count == 1, "exactly one bright quadrant detected", "got \(bright.count) of \(real.count)")
        if let box = bright.first {
            check(
                abs(box.rect.midX - 0.25) < 0.01 && abs(box.rect.midY - 0.25) < 0.01,
                "bright box is the top-left quadrant", "\(box.rect)"
            )
            check(box.confidence > 0.99, "brightness carried into confidence", "\(box.confidence)")
        }
        let dark = real.filter { $0.label == "dark" }
        check(dark.count == 3, "the other three quadrants report dark", "got \(dark.count)")

        report()
    }

    static func report() {
        print("\n\(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")")
        exit(failures == 0 ? 0 : 1)
    }

    /// 640x640 BGRA: top-left quadrant white, the rest black.
    static func makeQuadrantImage() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary
        CVPixelBufferCreate(nil, 640, 640, kCVPixelFormatType_32BGRA, attributes, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<640 {
            for x in 0..<640 {
                let value: UInt8 = (x < 320 && y < 320) ? 255 : 0
                let offset = y * stride + x * 4
                pixels[offset] = value; pixels[offset + 1] = value
                pixels[offset + 2] = value; pixels[offset + 3] = 255
            }
        }
        return buffer
    }
}
