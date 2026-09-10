import SwiftUI

// MARK: - Buttons

enum CarbonButtonKind {
    case primary, secondary, tertiary, ghost, danger

    var background: Color {
        switch self {
        case .primary: Carbon.buttonPrimary
        case .secondary: Carbon.buttonSecondary
        case .tertiary, .ghost: .clear
        case .danger: Carbon.buttonDanger
        }
    }

    var pressedBackground: Color {
        switch self {
        case .primary: Carbon.buttonPrimaryHover
        case .secondary: Carbon.buttonSecondaryHover
        case .tertiary: Carbon.textPrimary
        case .ghost: Carbon.layerHover01
        case .danger: CarbonSwatch.red70
        }
    }

    var foreground: Color {
        switch self {
        case .primary, .secondary, .danger: Carbon.textOnColor
        case .tertiary, .ghost: Carbon.textPrimary
        }
    }

    var pressedForeground: Color {
        self == .tertiary ? Carbon.textInverse : foreground
    }

    var border: Color {
        switch self {
        case .tertiary: Carbon.textPrimary
        default: .clear
        }
    }
}

enum CarbonButtonSize {
    /// Carbon `sm` - 32pt
    case small
    /// Carbon `md` - 40pt
    case medium
    /// Carbon `lg` - 48pt, the default for touch
    case large

    var height: CGFloat {
        switch self {
        case .small: 32
        case .medium: 40
        case .large: 48
        }
    }
}

/// A Carbon button: square corners, left-aligned label, icon pinned right.
struct CarbonButton: View {
    let title: String
    var systemImage: String?
    var kind: CarbonButtonKind = .primary
    var size: CarbonButtonSize = .large
    var fullWidth: Bool = true
    var isEnabled: Bool = true
    var isBusy: Bool = false
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s05) {
                Text(title)
                    .font(CarbonType.bodyCompact01())
                    .lineLimit(1)
                if fullWidth { Spacer(minLength: Space.s05) }
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(foreground)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .regular))
                }
            }
            .padding(.leading, Space.s05)
            .padding(.trailing, Space.s05 - (fullWidth ? 4 : 0))
            .fixedSize(horizontal: !fullWidth, vertical: false)
            .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
            .frame(height: size.height)
            .foregroundStyle(foreground)
            .background(background)
            .overlay(Rectangle().strokeBorder(borderColor, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isBusy)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !isPressed { isPressed = true } }
                .onEnded { _ in isPressed = false }
        )
        .animation(CarbonMotion.productive, value: isPressed)
    }

    private var background: Color {
        guard isEnabled else { return Carbon.buttonDisabled }
        return isPressed ? kind.pressedBackground : kind.background
    }

    private var foreground: Color {
        guard isEnabled else { return Carbon.textDisabled }
        return isPressed ? kind.pressedForeground : kind.foreground
    }

    private var borderColor: Color {
        isEnabled ? kind.border : .clear
    }
}

/// Square icon-only button, sized to Carbon's touch targets.
struct CarbonIconButton: View {
    let systemImage: String
    var accessibilityLabel: String
    var kind: CarbonButtonKind = .ghost
    var size: CGFloat = 48
    var isEnabled: Bool = true
    var isSelected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size >= 44 ? 18 : 15, weight: .regular))
                .frame(width: size, height: size)
                .foregroundStyle(isEnabled ? (isSelected ? Carbon.textOnColor : kind.foreground) : Carbon.iconDisabled)
                .background(isSelected ? Carbon.buttonPrimary : kind.background)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Tile

/// Carbon tile: a flat layer-01 surface with a 1px subtle border, no radius.
struct CarbonTile<Content: View>: View {
    var padding: CGFloat = Space.s05
    var layer: Color = Carbon.layer01
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(layer)
            .overlay(Rectangle().strokeBorder(Carbon.borderSubtle00, lineWidth: 1))
    }
}

/// A tile that behaves as a selectable option, with Carbon's left selection bar.
struct CarbonSelectableTile<Content: View>: View {
    var isSelected: Bool
    var action: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(isSelected ? Carbon.buttonPrimary : Color.clear)
                    .frame(width: 3)
                content()
                    .padding(Space.s05)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(isSelected ? Carbon.layer02 : Carbon.layer01)
            .overlay(Rectangle().strokeBorder(isSelected ? Carbon.borderStrong01 : Carbon.borderSubtle00, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(CarbonMotion.productive, value: isSelected)
    }
}

// MARK: - Tag

enum CarbonTagKind {
    case gray, red, green, blue, cyan, warning, outline

    var background: Color {
        switch self {
        case .gray: CarbonSwatch.gray70
        case .red: CarbonSwatch.red70
        case .green: CarbonSwatch.green60
        case .blue: CarbonSwatch.blue70
        case .cyan: Color(hex: 0x00539A)
        case .warning: Color(hex: 0x8E6A00)
        case .outline: .clear
        }
    }

    var foreground: Color {
        switch self {
        case .outline: Carbon.textSecondary
        default: CarbonSwatch.gray10
        }
    }
}

struct CarbonTag: View {
    let text: String
    var kind: CarbonTagKind = .gray
    var systemImage: String?

    var body: some View {
        HStack(spacing: Space.s02) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
            }
            Text(text)
                .font(CarbonType.label01())
                .lineLimit(1)
        }
        .padding(.horizontal, Space.s03)
        .padding(.vertical, Space.s01 + 1)
        .foregroundStyle(kind.foreground)
        .background(kind.background)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(kind == .outline ? Carbon.borderSubtle01 : .clear, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
    }
}

// MARK: - Notification

enum CarbonNotificationKind {
    case error, success, warning, info

    var accent: Color {
        switch self {
        case .error: Carbon.supportError
        case .success: Carbon.supportSuccess
        case .warning: Carbon.supportWarning
        case .info: Carbon.supportInfo
        }
    }

    var icon: String {
        switch self {
        case .error: "exclamationmark.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }
}

/// Carbon inline notification: 3px status bar on the left, square corners.
struct CarbonInlineNotification: View {
    let kind: CarbonNotificationKind
    let title: String
    var message: String?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(kind.accent).frame(width: 3)
            HStack(alignment: .top, spacing: Space.s04) {
                Image(systemName: kind.icon)
                    .font(.system(size: 16))
                    .foregroundStyle(kind.accent)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: Space.s01) {
                    Text(title)
                        .font(CarbonType.headingCompact01())
                        .foregroundStyle(Carbon.textPrimary)
                    if let message {
                        Text(message)
                            .font(CarbonType.bodyCompact01())
                            .foregroundStyle(Carbon.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Space.s03)
                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Carbon.iconPrimary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Space.s05)
        }
        .background(Carbon.layer02)
        .overlay(Rectangle().strokeBorder(Carbon.borderSubtle01, lineWidth: 1))
    }
}

// MARK: - Slider

/// Carbon slider: a 2px rail with a square handle and a bordered value box.
/// SwiftUI's own `Slider` is a rounded iOS control, so the track and handle are
/// drawn here to keep the square language the rest of the app uses.
struct CarbonSlider: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double = 0.01
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    private let handle: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s03) {
            Text(label)
                .font(CarbonType.label01())
                .foregroundStyle(Carbon.textSecondary)

            HStack(spacing: Space.s05) {
                GeometryReader { geometry in
                    let width = max(handle, geometry.size.width)
                    let travel = width - handle
                    let fraction = normalised
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Carbon.borderSubtle01)
                            .frame(height: 2)
                        Rectangle()
                            .fill(Carbon.textPrimary)
                            .frame(width: handle / 2 + travel * fraction, height: 2)
                        Rectangle()
                            .fill(Carbon.textPrimary)
                            .frame(width: handle, height: handle)
                            .offset(x: travel * fraction)
                    }
                    .frame(height: handle)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { gesture in
                                let x = min(max(0, gesture.location.x - handle / 2), travel)
                                update(to: travel > 0 ? x / travel : 0)
                            }
                    )
                }
                .frame(height: handle)

                Text(format(value))
                    .font(CarbonType.code01())
                    .foregroundStyle(Carbon.textPrimary)
                    .frame(width: 56, height: 32)
                    .background(Carbon.field01)
                    .overlay(Rectangle().strokeBorder(Carbon.borderStrong01, lineWidth: 1))
            }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? step : -step
            value = min(range.upperBound, max(range.lowerBound, value + delta))
        }
    }

    private var normalised: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / span))
    }

    private func update(to fraction: Double) {
        let span = range.upperBound - range.lowerBound
        let raw = range.lowerBound + fraction * span
        let stepped = step > 0 ? (raw / step).rounded() * step : raw
        value = min(range.upperBound, max(range.lowerBound, stepped))
    }
}

// MARK: - Toggle

struct CarbonToggle: View {
    let title: String
    var caption: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: Space.s05) {
            VStack(alignment: .leading, spacing: Space.s01) {
                Text(title)
                    .font(CarbonType.bodyCompact01())
                    .foregroundStyle(Carbon.textPrimary)
                if let caption {
                    Text(caption)
                        .font(CarbonType.helperText01())
                        .foregroundStyle(Carbon.textHelper)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Space.s05)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Carbon.supportSuccess)
        }
    }
}

// MARK: - Section header

struct CarbonSectionHeader: View {
    let title: String
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s02) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Carbon.textHelper)
            if let caption {
                Text(caption)
                    .font(CarbonType.helperText01())
                    .foregroundStyle(Carbon.textPlaceholder)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Key/value row

struct CarbonDataRow: View {
    let key: String
    let value: String
    var valueColor: Color = Carbon.textPrimary
    var monospaced: Bool = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s05) {
            Text(key)
                .font(CarbonType.label01())
                .foregroundStyle(Carbon.textHelper)
            Spacer(minLength: Space.s04)
            Text(value)
                .font(monospaced ? CarbonType.code01() : CarbonType.bodyCompact01())
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, Space.s03)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Carbon.borderSubtle00).frame(height: 1)
        }
    }
}

// MARK: - Empty state

struct CarbonEmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Space.s05) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .thin))
                .foregroundStyle(Carbon.textPlaceholder)
            VStack(spacing: Space.s03) {
                Text(title)
                    .font(CarbonType.heading03())
                    .foregroundStyle(Carbon.textPrimary)
                Text(message)
                    .font(CarbonType.bodyCompact01())
                    .foregroundStyle(Carbon.textHelper)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                CarbonButton(title: actionTitle, systemImage: "arrow.right", fullWidth: false, action: action)
                    .padding(.top, Space.s02)
            }
        }
        .padding(Space.s07)
        .frame(maxWidth: 420)
    }
}
