import CoreML
import CoreGraphics
import Foundation

/// Turns a raw object-detection tensor into normalised boxes.
///
/// CoreML exports from the common detector toolchains disagree about layout, so
/// the decoder inspects the shape instead of trusting a configured format:
///
/// - `[1, 4 + C, A]`  Ultralytics v8/v9/v10/v11 - channels first, no objectness
/// - `[1, A, 4 + C]`  the same tensor transposed
/// - `[1, A, 5 + C]`  YOLOv5/v7 - objectness in channel 4
/// - `[1, A, 6]`      an export that already ran NMS: x1,y1,x2,y2,score,class
///
/// Box units are also inconsistent: some exports emit 0...1, others emit pixels
/// of the model input. The decoder measures the tensor and normalises.
enum DetectionDecoder {

    struct Options {
        var confidenceThreshold: Float = 0.35
        var iouThreshold: Float = 0.45
        var maxDetections: Int = 100
        /// Model input side length, used when boxes are in pixel units.
        var inputSize: CGSize = CGSize(width: 640, height: 640)
    }

    struct Layout: Equatable, CustomStringConvertible {
        enum Kind: Equatable {
            case channelsFirst                // [1, 4+C, A]
            case anchorsFirst                 // [1, A, 4+C]
            case channelsFirstWithObjectness  // [1, 5+C, A]
            case anchorsFirstWithObjectness   // [1, A, 5+C]
            case decodedBoxes                 // [1, A, 6]
        }

        let kind: Kind
        let anchorCount: Int
        let classCount: Int

        var description: String {
            switch kind {
            case .channelsFirst: "YOLO v8-style, channels first"
            case .anchorsFirst: "YOLO v8-style, anchors first"
            case .channelsFirstWithObjectness: "YOLO v5-style with objectness, channels first"
            case .anchorsFirstWithObjectness: "YOLO v5-style with objectness, anchors first"
            case .decodedBoxes: "Pre-decoded boxes"
            }
        }
    }

    // MARK: - Layout detection

    /// Works out how to read `array`. `expectedClassCount` comes from the label
    /// file when the operator supplied one; it breaks ties on ambiguous shapes.
    static func layout(for array: MLMultiArray, expectedClassCount: Int?) -> Layout? {
        // Drop a leading batch dimension of 1.
        var dims = array.shape.map(\.intValue)
        if dims.first == 1 { dims.removeFirst() }
        guard dims.count == 2 else { return nil }

        let a = dims[0], b = dims[1]

        if b == 6 && a > 6 {
            return Layout(kind: .decodedBoxes, anchorCount: a, classCount: 0)
        }

        // Try both axis assignments, preferring the one where anchors outnumber
        // channels, which is what every real detector tensor looks like.
        let candidates: [(channels: Int, anchors: Int, channelsFirst: Bool)] = a <= b
            ? [(a, b, true), (b, a, false)]
            : [(b, a, false), (a, b, true)]

        if let expected = expectedClassCount, expected > 0 {
            for candidate in candidates {
                if candidate.channels == expected + 4 {
                    return Layout(
                        kind: candidate.channelsFirst ? .channelsFirst : .anchorsFirst,
                        anchorCount: candidate.anchors,
                        classCount: expected
                    )
                }
                if candidate.channels == expected + 5 {
                    return Layout(
                        kind: candidate.channelsFirst
                            ? .channelsFirstWithObjectness
                            : .anchorsFirstWithObjectness,
                        anchorCount: candidate.anchors,
                        classCount: expected
                    )
                }
            }
        }

        // No label file, or it disagrees with every axis: fall back on the
        // channel count of the shorter axis. 85 is the classic COCO YOLOv5
        // tensor, so prefer the objectness reading there.
        guard let best = candidates.first, best.channels > 4 else { return nil }
        if best.channels == 85 {
            return Layout(
                kind: best.channelsFirst ? .channelsFirstWithObjectness : .anchorsFirstWithObjectness,
                anchorCount: best.anchors,
                classCount: 80
            )
        }
        return Layout(
            kind: best.channelsFirst ? .channelsFirst : .anchorsFirst,
            anchorCount: best.anchors,
            classCount: best.channels - 4
        )
    }

    // MARK: - Decoding

    static func decode(
        _ array: MLMultiArray,
        layout: Layout,
        labels: LabelSet,
        options: Options
    ) -> [Detection] {
        FloatTensor.borrow(array) { pointer in
            decode(pointer, of: array, layout: layout, labels: labels, options: options)
        } ?? []
    }

    private static func decode(
        _ pointer: UnsafeBufferPointer<Float>,
        of array: MLMultiArray,
        layout: Layout,
        labels: LabelSet,
        options: Options
    ) -> [Detection] {
        var candidates: [Candidate] = []
        candidates.reserveCapacity(256)

        var dims = array.shape.map(\.intValue)
        if dims.first == 1 { dims.removeFirst() }
        guard dims.count == 2 else { return [] }

        let strides = array.strides.map(\.intValue)
        let rowStride = strides.count >= 2 ? strides[strides.count - 2] : dims[1]
        let columnStride = strides.last ?? 1

        @inline(__always)
        func value(_ row: Int, _ column: Int) -> Float {
            pointer[row * rowStride + column * columnStride]
        }

        switch layout.kind {
        case .decodedBoxes:
            for anchor in 0..<layout.anchorCount {
                let score = value(anchor, 4)
                guard score >= options.confidenceThreshold else { continue }
                let classIndex = Int(value(anchor, 5).rounded())
                let rect = CGRect(
                    x: CGFloat(value(anchor, 0)),
                    y: CGFloat(value(anchor, 1)),
                    width: CGFloat(value(anchor, 2) - value(anchor, 0)),
                    height: CGFloat(value(anchor, 3) - value(anchor, 1))
                )
                candidates.append(Candidate(rect: rect, score: score, classIndex: classIndex))
            }

        case .channelsFirst:
            // value(channel, anchor)
            for anchor in 0..<layout.anchorCount {
                var best: Float = 0
                var bestIndex = 0
                for c in 0..<layout.classCount {
                    let score = value(4 + c, anchor)
                    if score > best { best = score; bestIndex = c }
                }
                guard best >= options.confidenceThreshold else { continue }
                candidates.append(Candidate(
                    rect: centreRect(
                        value(0, anchor), value(1, anchor), value(2, anchor), value(3, anchor)
                    ),
                    score: best,
                    classIndex: bestIndex
                ))
            }

        case .anchorsFirst:
            for anchor in 0..<layout.anchorCount {
                var best: Float = 0
                var bestIndex = 0
                for c in 0..<layout.classCount {
                    let score = value(anchor, 4 + c)
                    if score > best { best = score; bestIndex = c }
                }
                guard best >= options.confidenceThreshold else { continue }
                candidates.append(Candidate(
                    rect: centreRect(
                        value(anchor, 0), value(anchor, 1), value(anchor, 2), value(anchor, 3)
                    ),
                    score: best,
                    classIndex: bestIndex
                ))
            }

        case .channelsFirstWithObjectness:
            for anchor in 0..<layout.anchorCount {
                let objectness = value(4, anchor)
                guard objectness >= options.confidenceThreshold * 0.5 else { continue }
                var best: Float = 0
                var bestIndex = 0
                for c in 0..<layout.classCount {
                    let score = value(5 + c, anchor)
                    if score > best { best = score; bestIndex = c }
                }
                let combined = best * objectness
                guard combined >= options.confidenceThreshold else { continue }
                candidates.append(Candidate(
                    rect: centreRect(
                        value(0, anchor), value(1, anchor), value(2, anchor), value(3, anchor)
                    ),
                    score: combined,
                    classIndex: bestIndex
                ))
            }

        case .anchorsFirstWithObjectness:
            for anchor in 0..<layout.anchorCount {
                let objectness = value(anchor, 4)
                guard objectness >= options.confidenceThreshold * 0.5 else { continue }
                var best: Float = 0
                var bestIndex = 0
                for c in 0..<layout.classCount {
                    let score = value(anchor, 5 + c)
                    if score > best { best = score; bestIndex = c }
                }
                let combined = best * objectness
                guard combined >= options.confidenceThreshold else { continue }
                candidates.append(Candidate(
                    rect: centreRect(
                        value(anchor, 0), value(anchor, 1), value(anchor, 2), value(anchor, 3)
                    ),
                    score: combined,
                    classIndex: bestIndex
                ))
            }
        }

        guard !candidates.isEmpty else { return [] }
        normalise(&candidates, inputSize: options.inputSize)

        let kept = nonMaximumSuppression(
            candidates,
            iouThreshold: options.iouThreshold,
            limit: options.maxDetections
        )
        return kept.map {
            Detection(
                classIndex: $0.classIndex,
                label: labels.name(for: $0.classIndex),
                confidence: $0.score,
                rect: $0.rect
            )
        }
    }

    // MARK: - Two-output NMS pipelines

    /// Some CoreML exports ship a built-in NMS stage that emits two tensors:
    /// `confidence` `[N, C]` and `coordinates` `[N, 4]` in cx,cy,w,h.
    static func decodePipeline(
        confidence: MLMultiArray,
        coordinates: MLMultiArray,
        labels: LabelSet,
        options: Options
    ) -> [Detection] {
        FloatTensor.borrow(confidence) { confidencePointer in
            FloatTensor.borrow(coordinates) { coordinatePointer in
                decodePipeline(
                    confidencePointer: confidencePointer,
                    coordinatePointer: coordinatePointer,
                    confidence: confidence,
                    labels: labels,
                    options: options
                )
            } ?? []
        } ?? []
    }

    private static func decodePipeline(
        confidencePointer: UnsafeBufferPointer<Float>,
        coordinatePointer: UnsafeBufferPointer<Float>,
        confidence: MLMultiArray,
        labels: LabelSet,
        options: Options
    ) -> [Detection] {
        var confidenceDims = confidence.shape.map(\.intValue)
        if confidenceDims.first == 1 && confidenceDims.count > 2 { confidenceDims.removeFirst() }
        guard confidenceDims.count == 2 else { return [] }
        let boxCount = confidenceDims[0]
        let classCount = confidenceDims[1]

        var detections: [Detection] = []
        for box in 0..<boxCount {
            var best: Float = 0
            var bestIndex = 0
            for c in 0..<classCount {
                let score = confidencePointer[box * classCount + c]
                if score > best { best = score; bestIndex = c }
            }
            guard best >= options.confidenceThreshold else { continue }
            let base = box * 4
            let rect = centreRect(
                coordinatePointer[base], coordinatePointer[base + 1],
                coordinatePointer[base + 2], coordinatePointer[base + 3]
            )
            detections.append(Detection(
                classIndex: bestIndex,
                label: labels.name(for: bestIndex),
                confidence: best,
                rect: rect
            ))
        }
        return Array(detections.sorted { $0.confidence > $1.confidence }.prefix(options.maxDetections))
    }

    // MARK: - Helpers

    struct Candidate {
        var rect: CGRect
        var score: Float
        var classIndex: Int
    }

    @inline(__always)
    private static func centreRect(_ cx: Float, _ cy: Float, _ w: Float, _ h: Float) -> CGRect {
        CGRect(
            x: CGFloat(cx - w / 2),
            y: CGFloat(cy - h / 2),
            width: CGFloat(w),
            height: CGFloat(h)
        )
    }

    /// Rescales pixel-unit boxes into 0...1, then clamps to the frame.
    private static func normalise(_ candidates: inout [Candidate], inputSize: CGSize) {
        let widest = candidates.reduce(CGFloat(0)) { max($0, $1.rect.maxX, $1.rect.maxY) }
        if widest > 1.5 {
            let sx = inputSize.width > 0 ? inputSize.width : 640
            let sy = inputSize.height > 0 ? inputSize.height : 640
            for index in candidates.indices {
                candidates[index].rect = CGRect(
                    x: candidates[index].rect.minX / sx,
                    y: candidates[index].rect.minY / sy,
                    width: candidates[index].rect.width / sx,
                    height: candidates[index].rect.height / sy
                )
            }
        }
        for index in candidates.indices {
            candidates[index].rect = candidates[index].rect.clampedToUnitSquare()
        }
        candidates.removeAll { $0.rect.width <= 0.001 || $0.rect.height <= 0.001 }
    }

    /// Greedy per-class non-maximum suppression.
    static func nonMaximumSuppression(
        _ candidates: [Candidate],
        iouThreshold: Float,
        limit: Int
    ) -> [Candidate] {
        var byClass: [Int: [Candidate]] = [:]
        for candidate in candidates { byClass[candidate.classIndex, default: []].append(candidate) }

        var kept: [Candidate] = []
        for (_, group) in byClass {
            let sorted = group.sorted { $0.score > $1.score }
            var selected: [Candidate] = []
            for candidate in sorted {
                var overlaps = false
                for chosen in selected where intersectionOverUnion(candidate.rect, chosen.rect) > iouThreshold {
                    overlaps = true
                    break
                }
                if !overlaps { selected.append(candidate) }
                if selected.count >= limit { break }
            }
            kept.append(contentsOf: selected)
        }
        return Array(kept.sorted { $0.score > $1.score }.prefix(limit))
    }

    @inline(__always)
    static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> Float {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let union = a.width * a.height + b.width * b.height - intersectionArea
        guard union > 0 else { return 0 }
        return Float(intersectionArea / union)
    }
}

extension CGRect {
    func clampedToUnitSquare() -> CGRect {
        let minX = Swift.max(0, Swift.min(1, self.minX))
        let minY = Swift.max(0, Swift.min(1, self.minY))
        let maxX = Swift.max(0, Swift.min(1, self.maxX))
        let maxY = Swift.max(0, Swift.min(1, self.maxY))
        return CGRect(x: minX, y: minY, width: Swift.max(0, maxX - minX), height: Swift.max(0, maxY - minY))
    }
}

/// Borrows an `MLMultiArray` as a flat float buffer.
///
/// Float32 tensors - which is what every export the app has met produces - are
/// read in place. Other element types are converted into a scratch buffer that
/// lives only for the duration of the call, so nothing leaks per frame.
enum FloatTensor {
    static func borrow<R>(
        _ array: MLMultiArray,
        _ body: (UnsafeBufferPointer<Float>) -> R
    ) -> R? {
        switch array.dataType {
        case .float32:
            return array.withUnsafeBufferPointer(ofType: Float.self) { body($0) }
        case .float16:
            return array.withUnsafeBufferPointer(ofType: Float16.self) { source in
                var scratch = [Float](repeating: 0, count: source.count)
                for index in source.indices { scratch[index] = Float(source[index]) }
                return scratch.withUnsafeBufferPointer { body($0) }
            }
        case .double:
            return array.withUnsafeBufferPointer(ofType: Double.self) { source in
                var scratch = [Float](repeating: 0, count: source.count)
                for index in source.indices { scratch[index] = Float(source[index]) }
                return scratch.withUnsafeBufferPointer { body($0) }
            }
        case .int32:
            return array.withUnsafeBufferPointer(ofType: Int32.self) { source in
                var scratch = [Float](repeating: 0, count: source.count)
                for index in source.indices { scratch[index] = Float(source[index]) }
                return scratch.withUnsafeBufferPointer { body($0) }
            }
        default:
            // MLMultiArrayDataType carries aliased cases, so this default also
            // covers .float / .float64 and anything a later SDK adds.
            return nil
        }
    }
}
