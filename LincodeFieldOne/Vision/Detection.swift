import CoreGraphics
import Foundation
import SwiftUI

/// One detected object in a frame.
struct Detection: Identifiable, Hashable {
    let id: UUID
    let classIndex: Int
    let label: String
    let confidence: Float
    /// Normalised to the source frame, origin top-left, y growing downward.
    let rect: CGRect

    init(
        id: UUID = UUID(),
        classIndex: Int,
        label: String,
        confidence: Float,
        rect: CGRect
    ) {
        self.id = id
        self.classIndex = classIndex
        self.label = label
        self.confidence = confidence
        self.rect = rect
    }

    var color: Color { Carbon.categoricalColor(for: classIndex) }

    var confidencePercent: String {
        "\(Int((confidence * 100).rounded()))%"
    }
}

/// The result of running one frame through the active model.
struct InferenceResult {
    let detections: [Detection]
    /// Pixel dimensions of the frame the detections belong to.
    let frameSize: CGSize
    let inferenceMilliseconds: Double
    let completedAt: CFTimeInterval

    static let empty = InferenceResult(
        detections: [], frameSize: .zero, inferenceMilliseconds: 0, completedAt: 0
    )
}

/// Rolling throughput figures shown on the live view.
struct InferenceStats {
    private(set) var framesPerSecond: Double = 0
    private(set) var averageMilliseconds: Double = 0
    private(set) var totalFrames: Int = 0

    private var lastFrameAt: CFTimeInterval?
    private var intervalAverage: Double = 0

    mutating func record(milliseconds: Double, at time: CFTimeInterval) {
        totalFrames += 1
        averageMilliseconds = averageMilliseconds == 0
            ? milliseconds
            : averageMilliseconds * 0.85 + milliseconds * 0.15

        if let last = lastFrameAt {
            let interval = time - last
            if interval > 0 {
                intervalAverage = intervalAverage == 0
                    ? interval
                    : intervalAverage * 0.85 + interval * 0.15
                framesPerSecond = 1.0 / intervalAverage
            }
        }
        lastFrameAt = time
    }

    mutating func reset() {
        self = InferenceStats()
    }
}
