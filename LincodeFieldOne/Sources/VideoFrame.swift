import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO

/// One decoded image handed to the inference pipeline.
///
/// Sources deliver whichever representation they own natively: AVFoundation
/// gives pixel buffers, the FIELD ONE VLC tap and camera photos give
/// `CGImage`s. Vision accepts both, and the capture compositor converts on
/// demand. Kept free of UIKit so the Mac-side checks can run the detector.
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
