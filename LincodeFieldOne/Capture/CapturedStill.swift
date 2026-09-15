import CoreGraphics
import Foundation
import ImageIO

/// Where a saved frame's pixels came from.
///
/// The FIELD ONE SDK requires these to stay distinct: a camera photo, a frame
/// lifted from the live preview, and a frame recovered from a closed recording
/// are different kinds of evidence and must never be labelled as each other.
enum CaptureProvenance: String, Codable, Equatable {
    /// A new JPEG taken by the FIELD ONE camera's own shutter.
    case cameraPhoto
    /// The current decoded frame of a live video stream.
    case livePreviewFrame
    /// A frame read back from a closed camera recording.
    case recoveredRecordingFrame

    var title: String {
        switch self {
        case .cameraPhoto: "Camera photo"
        case .livePreviewFrame: "Live preview frame"
        case .recoveredRecordingFrame: "Recovered recording frame"
        }
    }
}

/// What the camera reported about a photo it took.
struct CameraPhotoMetadata: Codable, Equatable {
    var handle: UInt32
    var filename: String
    var byteCount: Int
    var width: Int
    var height: Int
    /// From shutter request to completed download.
    var latencyMs: Double
    var deviceCapturedAt: Date?

    var megapixelsText: String {
        String(format: "%.1f MP", Double(width * height) / 1_000_000)
    }
}

/// A still ready for inference and saving.
struct CapturedStill {
    /// Upright pixels at full resolution.
    let frame: VideoFrame
    let provenance: CaptureProvenance
    /// The source's own encoded bytes, kept verbatim as evidence when present.
    let encodedJPEG: Data?
    let camera: CameraPhotoMetadata?
}

/// Decodes camera JPEGs into upright, full-resolution pixels.
enum StillImageDecoder {
    enum DecodeError: LocalizedError {
        case unreadable

        var errorDescription: String? {
            "The camera returned a photo that could not be decoded."
        }
    }

    /// Pixel dimensions as stored, before EXIF orientation.
    static func storedPixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Decodes at full size with any EXIF orientation applied, so boxes the
    /// model returns map straight onto what a viewer shows.
    static func uprightImage(from data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let stored = storedPixelSize(of: data) else { throw DecodeError.unreadable }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(stored.width, stored.height)),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw DecodeError.unreadable
        }
        return image
    }

    /// A reduced copy for on-screen display, without decoding the full image.
    static func downsampledImage(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}
