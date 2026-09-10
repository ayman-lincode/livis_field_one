import SwiftUI

/// Raw IBM Carbon Design System colour swatches.
/// Values transcribed from carbondesignsystem.com/elements/color/tokens.
/// Nothing in the app reads these directly - use `Carbon` semantic tokens instead.
enum CarbonSwatch {
    // Gray
    static let gray10 = Color(hex: 0xF4F4F4)
    static let gray20 = Color(hex: 0xE0E0E0)
    static let gray30 = Color(hex: 0xC6C6C6)
    static let gray40 = Color(hex: 0xA8A8A8)
    static let gray50 = Color(hex: 0x8D8D8D)
    static let gray60 = Color(hex: 0x6F6F6F)
    static let gray70 = Color(hex: 0x525252)
    static let gray80 = Color(hex: 0x393939)
    static let gray90 = Color(hex: 0x262626)
    static let gray100 = Color(hex: 0x161616)

    // Blue
    static let blue30 = Color(hex: 0xA6C8FF)
    static let blue40 = Color(hex: 0x78A9FF)
    static let blue50 = Color(hex: 0x4589FF)
    static let blue60 = Color(hex: 0x0F62FE)
    static let blue70 = Color(hex: 0x0043CE)
    static let blue80 = Color(hex: 0x002D9C)

    // Red
    static let red30 = Color(hex: 0xFFB3B8)
    static let red40 = Color(hex: 0xFF8389)
    static let red50 = Color(hex: 0xFA4D56)
    static let red60 = Color(hex: 0xDA1E28)
    static let red70 = Color(hex: 0xA2191F)

    // Green
    static let green30 = Color(hex: 0x6FDC8C)
    static let green40 = Color(hex: 0x42BE65)
    static let green50 = Color(hex: 0x24A148)
    static let green60 = Color(hex: 0x198038)

    // Yellow / orange
    static let yellow30 = Color(hex: 0xF1C21B)
    static let orange40 = Color(hex: 0xFF832B)

    // Accents used by the data-visualisation palette
    static let purple50 = Color(hex: 0xA56EFF)
    static let teal50 = Color(hex: 0x009D9A)
    static let cyan50 = Color(hex: 0x1192E8)
    static let magenta50 = Color(hex: 0xEE5396)
}

/// Lincode brand marks, sampled from the Lincode / LIVIS Edge asset library.
enum LincodeBrand {
    /// The Lincode wordmark red.
    static let red = Color(hex: 0xC2342E)
    static let redPressed = Color(hex: 0x9E2A25)
    /// The lighter red used on the LIVIS Edge lockup.
    static let redLight = Color(hex: 0xE05A54)
    /// Wordmark type colour on dark surfaces - already a Carbon gray 10.
    static let wordmark = CarbonSwatch.gray10
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
