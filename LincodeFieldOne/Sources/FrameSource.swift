import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import UIKit

/// One decoded video frame handed to the inference pipeline.
///
/// Sources deliver whichever representation they own natively: AVFoundation
/// gives pixel buffers, the FIELD ONE VLC tap gives `CGImage`s. Vision accepts
/// both, and the capture compositor converts on demand.
struct VideoFrame {
    enum Image {
        case pixelBuffer(CVPixelBuffer)
        case cgImage(CGImage)
    }

    let image: Image
    /// Pixel dimensions of `image`, before any orientation is applied.
    let size: CGSize
    let orientation: CGImagePropertyOrientation
    let capturedAt: CFTimeInterval

    /// Dimensions as displayed, after `orientation` is applied.
    var displaySize: CGSize {
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            CGSize(width: size.height, height: size.width)
        default:
            size
        }
    }

    func makeCGImage() -> CGImage? {
        switch image {
        case .cgImage(let cgImage):
            return cgImage
        case .pixelBuffer(let buffer):
            let ciImage = CIImage(cvPixelBuffer: buffer)
            return SharedCIContext.shared.createCGImage(ciImage, from: ciImage.extent)
        }
    }
}

enum SharedCIContext {
    static let shared = CIContext(options: [.useSoftwareRenderer: false])
}

/// Where live video comes from.
enum FrameSourceKind: String, CaseIterable, Identifiable, Codable {
    /// ENDLESSRIVER FIELD ONE over Wi-Fi, through the client SDK.
    case fieldOne
    /// This iPhone's own camera. Used for bench testing a model when the
    /// FIELD ONE hardware is not to hand.
    case deviceCamera

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fieldOne: "FIELD ONE"
        case .deviceCamera: "This iPhone"
        }
    }

    var subtitle: String {
        switch self {
        case .fieldOne: "ENDLESSRIVER wearable camera over Wi-Fi"
        case .deviceCamera: "Built-in camera, for bench testing a model"
        }
    }

    var systemImage: String {
        switch self {
        case .fieldOne: "wave.3.right.circle"
        case .deviceCamera: "iphone.gen3.camera"
        }
    }
}

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

    /// A full-quality still of the present moment, for the capture action.
    func captureStill() async throws -> VideoFrame
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
