import SwiftUI

/// Draws detection boxes over the live video.
///
/// Boxes arrive normalised to the frame. The video itself is letterboxed inside
/// the preview, so the overlay recomputes that same rectangle and maps into it.
/// Anything outside the video rectangle is left untouched.
struct DetectionOverlay: View {
    let detections: [Detection]
    /// Pixel dimensions of the frame the detections were measured in.
    let frameSize: CGSize?
    var showLabels: Bool = true
    var showConfidence: Bool = true
    /// Dims the letterbox bars so the video edge reads clearly.
    var showsFrameGuide: Bool = true

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let video = aspectFitRect(
                content: frameSize ?? CGSize(width: 16, height: 9), in: bounds
            )

            ZStack(alignment: .topLeading) {
                if showsFrameGuide {
                    Rectangle()
                        .strokeBorder(Carbon.borderSubtle01.opacity(0.5), lineWidth: 1)
                        .frame(width: video.width, height: video.height)
                        .offset(x: video.minX, y: video.minY)
                }

                // Identified by slot, not by the per-frame detection id, so a
                // box that persists across frames moves instead of being torn
                // down and rebuilt thirty times a second.
                ForEach(Array(detections.enumerated()), id: \.offset) { _, detection in
                    let rect = place(detection.rect, in: video)
                    DetectionBox(
                        detection: detection,
                        rect: rect,
                        containerWidth: video.maxX,
                        showLabel: showLabels,
                        showConfidence: showConfidence
                    )
                }
            }
            .animation(CarbonMotion.productive, value: detections.count)
        }
        .allowsHitTesting(false)
    }

    private func place(_ normalised: CGRect, in video: CGRect) -> CGRect {
        CGRect(
            x: video.minX + normalised.minX * video.width,
            y: video.minY + normalised.minY * video.height,
            width: normalised.width * video.width,
            height: normalised.height * video.height
        )
    }
}

private struct DetectionBox: View {
    let detection: Detection
    let rect: CGRect
    let containerWidth: CGFloat
    let showLabel: Bool
    let showConfidence: Bool

    private var color: Color { detection.color }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(color, lineWidth: 2)
                .background(Rectangle().fill(color.opacity(0.08)))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)

            // Carbon corner ticks: four short strokes that stay visible when
            // the box is small or the subject is busy.
            CornerTicks(color: color)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)

            if showLabel {
                label
                    .offset(x: labelOrigin.x, y: labelOrigin.y)
            }
        }
    }

    private var label: some View {
        HStack(spacing: Space.s02) {
            Text(detection.label)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            if showConfidence {
                Text(detection.confidencePercent)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .opacity(0.85)
            }
        }
        .padding(.horizontal, Space.s03)
        .padding(.vertical, 3)
        .foregroundStyle(Color.white)
        .background(color)
        .fixedSize()
    }

    private var labelOrigin: CGPoint {
        let height: CGFloat = 20
        let y = rect.minY - height >= 0 ? rect.minY - height : rect.minY
        return CGPoint(x: rect.minX, y: y)
    }
}

private struct CornerTicks: View {
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let arm = min(14, min(size.width, size.height) * 0.3)
            Path { path in
                // top-left
                path.move(to: CGPoint(x: 0, y: arm)); path.addLine(to: .zero)
                path.addLine(to: CGPoint(x: arm, y: 0))
                // top-right
                path.move(to: CGPoint(x: size.width - arm, y: 0))
                path.addLine(to: CGPoint(x: size.width, y: 0))
                path.addLine(to: CGPoint(x: size.width, y: arm))
                // bottom-right
                path.move(to: CGPoint(x: size.width, y: size.height - arm))
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.addLine(to: CGPoint(x: size.width - arm, y: size.height))
                // bottom-left
                path.move(to: CGPoint(x: arm, y: size.height))
                path.addLine(to: CGPoint(x: 0, y: size.height))
                path.addLine(to: CGPoint(x: 0, y: size.height - arm))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .butt, lineJoin: .miter))
        }
    }
}
