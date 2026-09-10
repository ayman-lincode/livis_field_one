import SwiftUI

/// Renders the Lincode wordmark at any size, in its brand colours.
struct LincodeLogo: View {
    var height: CGFloat = 20
    /// Colour used for the letterforms that are red in the brand file.
    var brandInk: Color = LincodeBrand.red
    /// Colour used for the letterforms that are light in the brand file.
    var wordmarkInk: Color = LincodeBrand.wordmark

    private var aspect: CGFloat {
        LincodeMark.viewBox.width / LincodeMark.viewBox.height
    }

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            for stroke in LincodeMark.strokes {
                let path = Path(
                    SVGPath.cgPath(from: stroke.data, in: LincodeMark.viewBox, fittingInto: rect)
                )
                context.fill(path, with: .color(stroke.ink == .brand ? brandInk : wordmarkInk))
            }
        }
        .frame(width: height * aspect, height: height)
        .accessibilityElement()
        .accessibilityLabel("Lincode")
    }
}

/// The app's product lockup: the Lincode mark above the product name.
struct ProductLockup: View {
    var logoHeight: CGFloat = 22
    var showsProduct: Bool = true

    var body: some View {
        HStack(spacing: Space.s04) {
            LincodeLogo(height: logoHeight)
            if showsProduct {
                Rectangle()
                    .fill(Carbon.borderSubtle01)
                    .frame(width: 1, height: logoHeight * 0.8)
                VStack(alignment: .leading, spacing: 0) {
                    Text("FIELD ONE")
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(1.4)
                        .foregroundStyle(Carbon.textPrimary)
                    Text("Vision Inspection")
                        .font(.system(size: 9, weight: .regular))
                        .tracking(0.8)
                        .foregroundStyle(Carbon.textHelper)
                }
            }
        }
    }
}

#Preview {
    VStack(spacing: 24) {
        LincodeLogo(height: 40)
        ProductLockup()
    }
    .padding(40)
    .background(Carbon.background)
}
