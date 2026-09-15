import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import UIKit

/// Lifecycle of a frame source, mapped to operator-facing wording.
enum SourceState: Equatable {
    case idle
    /// A step is in progress; the string is shown verbatim to the operator.
    case preparing(String)
    /// Decoded frames are arriving.
    case streaming
    case failed(String)

    var isStreaming: Bool { self == .streaming }

    var label: String {
        switch self {
        case .idle: "Not connected"
        case .preparing(let step): step
        case .streaming: "Live"
        case .failed: "Failed"
        }
    }
}

/// A live video source that can render itself and emit frames for inference.
@MainActor
protocol FrameSource: AnyObject {
    var kind: FrameSourceKind { get }
    var state: SourceState { get }
    /// Native pixel dimensions of the displayed video, once known.
    var displaySize: CGSize? { get }

    var onStateChange: ((SourceState) -> Void)? { get set }
    /// Called on the main actor for every frame sampled for inference.
    var onFrame: ((VideoFrame) -> Void)? { get set }

    /// The view that renders the live video. Owned by the source.
    func makePreviewView() -> UIView

    func start() async
    func stop()

    /// Frames per second at which `onFrame` is delivered. Sources may clamp.
    var samplingRate: Double { get set }

    /// Whether `captureStill` currently produces a camera photo rather than a
    /// frame lifted from the live stream.
    var capturesCameraPhotos: Bool { get }

    /// A full-quality still of the present moment, for the capture action.
    /// `progress` reports download bytes when the source has to fetch them.
    func captureStill(
        progress: @escaping @Sendable @MainActor (CaptureProgress) -> Void
    ) async throws -> CapturedStill
}

/// Stages of a capture, for the operator-facing progress overlay.
enum CaptureProgress: Equatable {
    case takingPhoto
    case downloading(received: UInt64, total: UInt64)

    var title: String {
        switch self {
        case .takingPhoto:
            "Taking photo"
        case .downloading(let received, let total):
            total > 0
                ? "Downloading \(Int(Double(received) / Double(total) * 100))%"
                : "Downloading"
        }
    }

    var fraction: Double? {
        guard case .downloading(let received, let total) = self, total > 0 else { return nil }
        return min(1, Double(received) / Double(total))
    }
}

enum FrameSourceError: LocalizedError {
    case notStreaming
    case stillUnavailable
    case permissionDenied
    case unsupportedOnThisDevice(String)

    var errorDescription: String? {
        switch self {
        case .notStreaming:
            "No live frames are arriving yet."
        case .stillUnavailable:
            "The camera did not return a frame to capture."
        case .permissionDenied:
            "Camera access is off for this app. Turn it on in Settings."
        case .unsupportedOnThisDevice(let detail):
            detail
        }
    }
}

/// Maps a video of `contentSize` into `bounds` the way both preview layers do
/// (aspect fit, letterboxed). The detection overlay and the capture compositor
/// both use this so a box drawn on screen lands on the same pixels in the file.
func aspectFitRect(content contentSize: CGSize, in bounds: CGRect) -> CGRect {
    guard contentSize.width > 0, contentSize.height > 0,
          bounds.width > 0, bounds.height > 0 else { return bounds }
    return AVMakeRect(aspectRatio: contentSize, insideRect: bounds)
}
