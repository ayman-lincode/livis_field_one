import SwiftUI

/// Carbon semantic colour tokens for the Gray 100 (darkest) theme.
///
/// FIELD ONE is an inspection tool used against a live video feed, so the app is
/// pinned to Carbon's darkest theme: video stays the brightest thing on screen.
enum Carbon {
    // MARK: Backgrounds and layers
    static let background = CarbonSwatch.gray100
    static let backgroundHover = Color(hex: 0x353535)
    static let backgroundInverse = CarbonSwatch.gray10

    static let layer01 = CarbonSwatch.gray90
    static let layer02 = CarbonSwatch.gray80
    static let layer03 = CarbonSwatch.gray70
    static let layerHover01 = Color(hex: 0x333333)
    static let layerHover02 = Color(hex: 0x474747)
    static let layerAccent01 = CarbonSwatch.gray80

    static let field01 = CarbonSwatch.gray90
    static let field02 = CarbonSwatch.gray80

    // MARK: Borders
    static let borderSubtle00 = CarbonSwatch.gray80
    static let borderSubtle01 = CarbonSwatch.gray70
    static let borderStrong01 = CarbonSwatch.gray60
    static let borderInverse = CarbonSwatch.gray10
    static let borderInteractive = CarbonSwatch.blue50

    // MARK: Text
    static let textPrimary = CarbonSwatch.gray10
    static let textSecondary = CarbonSwatch.gray30
    static let textPlaceholder = CarbonSwatch.gray60
    static let textHelper = CarbonSwatch.gray40
    static let textOnColor = Color.white
    static let textDisabled = CarbonSwatch.gray10.opacity(0.25)
    static let textInverse = CarbonSwatch.gray100
    static let textError = CarbonSwatch.red40

    // MARK: Icons
    static let iconPrimary = CarbonSwatch.gray10
    static let iconSecondary = CarbonSwatch.gray30
    static let iconOnColor = Color.white
    static let iconDisabled = CarbonSwatch.gray10.opacity(0.25)

    // MARK: Interactive
    /// Carbon's own interactive blue, kept for links and focus rings.
    static let interactive = CarbonSwatch.blue50
    static let focus = Color.white
    static let linkPrimary = CarbonSwatch.blue40

    /// Primary action colour. Carbon allows a brand override here; FIELD ONE
    /// uses the Lincode red so primary actions read as Lincode, not IBM.
    static let buttonPrimary = LincodeBrand.red
    static let buttonPrimaryHover = LincodeBrand.redPressed
    static let buttonSecondary = CarbonSwatch.gray60
    static let buttonSecondaryHover = CarbonSwatch.gray50
    static let buttonTertiaryText = CarbonSwatch.gray10
    static let buttonDanger = CarbonSwatch.red60
    static let buttonDisabled = CarbonSwatch.gray80

    // MARK: Support / status
    static let supportError = CarbonSwatch.red40
    static let supportSuccess = CarbonSwatch.green40
    static let supportWarning = CarbonSwatch.yellow30
    static let supportInfo = CarbonSwatch.blue50
    static let supportCautionMinor = CarbonSwatch.orange40

    // MARK: Overlay
    static let overlay = CarbonSwatch.gray100.opacity(0.7)
    static let skeleton = CarbonSwatch.gray80

    /// Carbon's categorical data-visualisation palette, used to colour detection
    /// classes so two adjacent classes never share a hue.
    static let categorical: [Color] = [
        Color(hex: 0x8A3FFC), Color(hex: 0x33B1FF), Color(hex: 0x007D79),
        Color(hex: 0xFF7EB6), Color(hex: 0xFA4D56), Color(hex: 0xFFF1F1),
        Color(hex: 0x6FDC8C), Color(hex: 0x4589FF), Color(hex: 0xD12771),
        Color(hex: 0xD2A106), Color(hex: 0x08BDBA), Color(hex: 0xBAE6FF),
        Color(hex: 0xBA4E00), Color(hex: 0xD4BBFF)
    ]

    static func categoricalColor(for index: Int) -> Color {
        guard !categorical.isEmpty else { return supportInfo }
        let i = index % categorical.count
        return categorical[i < 0 ? i + categorical.count : i]
    }
}

/// Carbon spacing scale (`$spacing-01` ... `$spacing-13`).
enum Space {
    static let s01: CGFloat = 2
    static let s02: CGFloat = 4
    static let s03: CGFloat = 8
    static let s04: CGFloat = 12
    static let s05: CGFloat = 16
    static let s06: CGFloat = 24
    static let s07: CGFloat = 32
    static let s08: CGFloat = 40
    static let s09: CGFloat = 48
    static let s10: CGFloat = 64
    static let s11: CGFloat = 80
    static let s12: CGFloat = 96
    static let s13: CGFloat = 160
}

/// Carbon border-radius tokens. Carbon is a square-cornered system: most
/// surfaces are 0 and only a few small affordances round at all.
enum Radius {
    /// Buttons, tiles, inputs, notifications - Carbon's default.
    static let none: CGFloat = 0
    /// `$border-radius-sm`
    static let sm: CGFloat = 2
    /// `$border-radius-md` - tags, small pills.
    static let md: CGFloat = 4
    /// `$border-radius-lg` - the largest Carbon radius, used sparingly.
    static let lg: CGFloat = 8
    /// Fully round: used only for the circular shutter control.
    static let full: CGFloat = 999
}

/// Carbon type scale. IBM Plex is not redistributable inside this package, so
/// the app renders the scale with the system face while keeping Carbon's
/// size, leading and weight relationships.
enum CarbonType {
    static func label01() -> Font { .system(size: 12, weight: .regular) }
    static func helperText01() -> Font { .system(size: 12, weight: .regular) }
    static func bodyCompact01() -> Font { .system(size: 14, weight: .regular) }
    static func body01() -> Font { .system(size: 14, weight: .regular) }
    static func body02() -> Font { .system(size: 16, weight: .regular) }
    static func headingCompact01() -> Font { .system(size: 14, weight: .semibold) }
    static func heading01() -> Font { .system(size: 14, weight: .semibold) }
    static func heading02() -> Font { .system(size: 16, weight: .semibold) }
    static func heading03() -> Font { .system(size: 20, weight: .regular) }
    static func heading04() -> Font { .system(size: 28, weight: .regular) }
    static func heading05() -> Font { .system(size: 32, weight: .regular) }
    static func code01() -> Font { .system(size: 12, weight: .regular, design: .monospaced) }
    static func code02() -> Font { .system(size: 14, weight: .regular, design: .monospaced) }
    /// Numeric readouts on the live view - tabular so digits do not jitter.
    static func metric() -> Font { .system(size: 14, weight: .medium, design: .monospaced) }
    static func metricLarge() -> Font { .system(size: 20, weight: .medium, design: .monospaced) }
}

/// Carbon motion curves.
enum CarbonMotion {
    static let productive = Animation.timingCurve(0.2, 0, 0.38, 0.9, duration: 0.11)
    static let productiveEntrance = Animation.timingCurve(0, 0, 0.38, 0.9, duration: 0.11)
    static let expressive = Animation.timingCurve(0.4, 0.14, 0.3, 1, duration: 0.24)
    static let expressiveEntrance = Animation.timingCurve(0, 0, 0.3, 1, duration: 0.24)
}
