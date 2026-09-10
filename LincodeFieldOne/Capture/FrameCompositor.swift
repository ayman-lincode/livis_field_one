import CoreGraphics
import Foundation
import UIKit

/// Burns detection boxes onto a captured frame.
///
/// Draws with the same normalised rectangles the live overlay uses, so the
/// saved file matches what the operator saw when they pressed capture.
enum FrameCompositor {

    struct Annotation {
        var detections: [Detection]
        var modelName: String
        var sourceName: String
        var capturedAt: Date
        var burnInMetadata: Bool = true
        /// Set when the frame is a recovered recording still rather than a live
        /// shutter, so the label on the image says so.
        var provenanceNote: String?
    }

    static func annotate(_ image: CGImage, with annotation: Annotation) -> UIImage {
        let size = CGSize(width: image.width, height: image.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            cg.saveGState()
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
            cg.draw(image, in: CGRect(origin: .zero, size: size))
            cg.restoreGState()

            // Line weights scale with the frame so a 4K still is not hairline.
            let unit = max(size.width, size.height) / 720
            let lineWidth = max(2, 3 * unit)
            let labelFontSize = max(11, 15 * unit)

            for detection in annotation.detections {
                let rect = CGRect(
                    x: detection.rect.minX * size.width,
                    y: detection.rect.minY * size.height,
                    width: detection.rect.width * size.width,
                    height: detection.rect.height * size.height
                )
                let color = UIColor(Carbon.categoricalColor(for: detection.classIndex))

                cg.setStrokeColor(color.cgColor)
                cg.setLineWidth(lineWidth)
                cg.stroke(rect)

                drawLabel(
                    "\(detection.label)  \(detection.confidencePercent)",
                    at: rect,
                    frameSize: size,
                    color: color,
                    fontSize: labelFontSize,
                    unit: unit,
                    in: cg
                )
            }

            if annotation.burnInMetadata {
                drawMetadataBar(annotation, size: size, unit: unit, in: cg)
            }
        }
    }

    // MARK: - Pieces

    private static func drawLabel(
        _ text: String,
        at rect: CGRect,
        frameSize: CGSize,
        color: UIColor,
        fontSize: CGFloat,
        unit: CGFloat,
        in context: CGContext
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: UIColor.white
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let padding = 5 * unit
        let chipHeight = textSize.height + padding

        // Carbon tags sit flush with the box: above it, or inside when clipped.
        var chip = CGRect(
            x: rect.minX,
            y: rect.minY - chipHeight,
            width: textSize.width + padding * 2,
            height: chipHeight
        )
        if chip.minY < 0 { chip.origin.y = rect.minY }
        if chip.maxX > frameSize.width { chip.origin.x = max(0, frameSize.width - chip.width) }

        context.setFillColor(color.cgColor)
        context.fill(chip)

        string.draw(at: CGPoint(x: chip.minX + padding, y: chip.minY + padding / 2))
    }

    private static func drawMetadataBar(
        _ annotation: Annotation,
        size: CGSize,
        unit: CGFloat,
        in context: CGContext
    ) {
        let fontSize = max(10, 13 * unit)
        let barHeight = fontSize * 2.6
        let bar = CGRect(x: 0, y: size.height - barHeight, width: size.width, height: barHeight)

        context.setFillColor(UIColor(Carbon.background).withAlphaComponent(0.86).cgColor)
        context.fill(bar)
        context.setFillColor(UIColor(LincodeBrand.red).cgColor)
        context.fill(CGRect(x: 0, y: bar.minY, width: size.width, height: max(1, 2 * unit)))

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let left = [
            annotation.sourceName,
            annotation.modelName,
            "\(annotation.detections.count) detection\(annotation.detections.count == 1 ? "" : "s")"
        ].joined(separator: "   |   ")

        let leftAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: UIColor(Carbon.textSecondary)
        ]
        NSAttributedString(string: left, attributes: leftAttributes)
            .draw(at: CGPoint(x: fontSize, y: bar.minY + (barHeight - fontSize * 1.2) / 2))

        let rightText = annotation.provenanceNote ?? formatter.string(from: annotation.capturedAt)
        let rightAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: UIColor(Carbon.textPrimary)
        ]
        let right = NSAttributedString(string: rightText, attributes: rightAttributes)
        right.draw(at: CGPoint(
            x: size.width - right.size().width - fontSize,
            y: bar.minY + (barHeight - fontSize * 1.2) / 2
        ))
    }
}
