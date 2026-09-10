import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case live, models, captures, device, settings

    var id: String { rawValue }

    /// Debug builds accept `-startTab <name>` so screenshots of each screen can
    /// be taken without driving touch input.
    static var launchArgumentTab: AppTab? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-startTab"),
              index + 1 < arguments.count else { return nil }
        return AppTab(rawValue: arguments[index + 1])
        #else
        return nil
        #endif
    }

    var title: String {
        switch self {
        case .live: "Live"
        case .models: "Models"
        case .captures: "Captures"
        case .device: "Device"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .live: "viewfinder"
        case .models: "cube.transparent"
        case .captures: "square.grid.2x2"
        case .device: "antenna.radiowaves.left.and.right"
        case .settings: "slider.horizontal.3"
        }
    }
}

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ModelStore.self) private var modelStore
    @Environment(CaptureStore.self) private var captureStore

    @State private var tab: AppTab = AppTab.launchArgumentTab ?? .live
    @State private var live: LiveViewModel?

    var body: some View {
        ZStack(alignment: .bottom) {
            Carbon.background.ignoresSafeArea()

            Group {
                switch tab {
                case .live:
                    if let live {
                        LiveInspectionView(model: live, openModels: { tab = .models })
                    }
                case .models:
                    ModelLibraryView()
                case .captures:
                    GalleryView()
                case .device:
                    DeviceView(source: live?.source as? FieldOneFrameSource)
                case .settings:
                    SettingsView(onDetectionSettingsChanged: {
                        live?.invalidateDetector()
                        live?.refreshSourceConfiguration()
                    })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, CarbonTabBar.height)

            CarbonTabBar(selection: $tab)
        }
        .background(Carbon.background)
        .task {
            if live == nil {
                live = LiveViewModel(
                    settings: settings, modelStore: modelStore, captureStore: captureStore
                )
            }
        }
    }
}

/// Carbon-flavoured bottom navigation: flat layer, square edges, a 2px brand
/// bar marking the active item rather than a rounded pill.
struct CarbonTabBar: View {
    @Binding var selection: AppTab
    static let height: CGFloat = 56

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    guard selection != tab else { return }
                    selection = tab
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    VStack(spacing: Space.s02) {
                        Rectangle()
                            .fill(selection == tab ? LincodeBrand.red : .clear)
                            .frame(height: 2)
                        Spacer(minLength: 0)
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 17, weight: .regular))
                        Text(tab.title)
                            .font(.system(size: 10, weight: selection == tab ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(selection == tab ? Carbon.textPrimary : Carbon.textPlaceholder)
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.height)
                    .background(selection == tab ? Carbon.layer02 : Carbon.layer01)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
            }
        }
        .background(Carbon.layer01)
        .overlay(alignment: .top) {
            Rectangle().fill(Carbon.borderSubtle00).frame(height: 1)
        }
        .animation(CarbonMotion.productive, value: selection)
    }
}

/// A Carbon page header: product lockup on the left, actions on the right.
struct CarbonPageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var showsLockup: Bool = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            if showsLockup {
                HStack {
                    ProductLockup()
                    Spacer()
                }
                .padding(.horizontal, Space.s05)
                .padding(.top, Space.s04)
                .padding(.bottom, Space.s03)
            }

            HStack(alignment: .firstTextBaseline, spacing: Space.s05) {
                VStack(alignment: .leading, spacing: Space.s01) {
                    Text(title)
                        .font(CarbonType.heading04())
                        .foregroundStyle(Carbon.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(CarbonType.helperText01())
                            .foregroundStyle(Carbon.textHelper)
                    }
                }
                Spacer(minLength: Space.s04)
                trailing()
            }
            .padding(.horizontal, Space.s05)
            .padding(.top, showsLockup ? Space.s03 : Space.s05)
            .padding(.bottom, Space.s05)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Carbon.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Carbon.borderSubtle00).frame(height: 1)
        }
    }
}

extension CarbonPageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, showsLockup: Bool = false) {
        self.init(title: title, subtitle: subtitle, showsLockup: showsLockup) { EmptyView() }
    }
}
