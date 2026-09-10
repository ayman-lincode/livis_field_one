import FieldOneSDK
import SwiftUI

/// Inference tuning, capture behaviour and FIELD ONE connection preferences.
struct SettingsView: View {
    var onDetectionSettingsChanged: () -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(ModelStore.self) private var modelStore

    var body: some View {
        @Bindable var settings = settings

        VStack(spacing: 0) {
            CarbonPageHeader(title: "Settings", subtitle: "Applies to the next frame")

            ScrollView {
                VStack(spacing: Space.s05) {
                    inference(settings: settings)
                    fitting(settings: settings)
                    compute(settings: settings)
                    overlaySection(settings: settings)
                    connection(settings: settings)
                    about
                }
                .padding(Space.s05)
            }
        }
        .background(Carbon.background)
    }

    private func inference(settings: AppSettings) -> some View {
        @Bindable var settings = settings
        return CarbonTile {
            VStack(alignment: .leading, spacing: Space.s06) {
                CarbonSectionHeader(
                    title: "Inference",
                    caption: "Higher thresholds mean fewer, surer boxes."
                )
                CarbonSlider(
                    label: "Confidence threshold",
                    value: $settings.detection.confidenceThreshold,
                    range: 0.05...0.95
                )
                CarbonSlider(
                    label: "Overlap threshold (IoU)",
                    value: $settings.detection.iouThreshold,
                    range: 0.1...0.9
                )
                CarbonSlider(
                    label: "Frames per second offered to the model",
                    value: $settings.detection.samplingRate,
                    range: 1...30,
                    step: 1,
                    format: { String(format: "%.0f", $0) }
                )
                CarbonSlider(
                    label: "Maximum boxes per frame",
                    value: Binding(
                        get: { Double(settings.detection.maxDetections) },
                        set: { settings.detection.maxDetections = Int($0) }
                    ),
                    range: 5...200,
                    step: 5,
                    format: { String(format: "%.0f", $0) }
                )
            }
        }
        .onChange(of: settings.detection) { _, _ in onDetectionSettingsChanged() }
    }

    private func fitting(settings: AppSettings) -> some View {
        @Bindable var settings = settings
        return CarbonTile {
            VStack(alignment: .leading, spacing: Space.s04) {
                CarbonSectionHeader(
                    title: "How the frame is fed to the model",
                    caption: "Change this if boxes are offset or squashed."
                )
                ForEach(InputFitting.allCases) { option in
                    CarbonSelectableTile(
                        isSelected: settings.detection.fitting == option,
                        action: { settings.detection.fitting = option }
                    ) {
                        VStack(alignment: .leading, spacing: Space.s01) {
                            Text(option.title)
                                .font(CarbonType.headingCompact01())
                                .foregroundStyle(Carbon.textPrimary)
                            Text(option.caption)
                                .font(CarbonType.helperText01())
                                .foregroundStyle(Carbon.textHelper)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func compute(settings: AppSettings) -> some View {
        @Bindable var settings = settings
        return CarbonTile {
            VStack(alignment: .leading, spacing: Space.s04) {
                CarbonSectionHeader(
                    title: "Compute",
                    caption: "Automatic lets Core ML choose. Changing this reloads the model."
                )
                HStack(spacing: Space.s02) {
                    ForEach(DetectionSettings.ComputeUnitsPreference.allCases) { option in
                        Button {
                            settings.detection.computeUnits = option
                        } label: {
                            Text(option.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(
                                    settings.detection.computeUnits == option
                                        ? Carbon.textOnColor : Carbon.textSecondary
                                )
                                .frame(maxWidth: .infinity)
                                .frame(height: 40)
                                .background(
                                    settings.detection.computeUnits == option
                                        ? Carbon.buttonPrimary : Carbon.layer02
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func overlaySection(settings: AppSettings) -> some View {
        @Bindable var settings = settings
        return CarbonTile {
            VStack(alignment: .leading, spacing: Space.s05) {
                CarbonSectionHeader(title: "Overlay and capture")
                CarbonToggle(title: "Show class names", isOn: $settings.showLabels)
                CarbonToggle(title: "Show confidence", isOn: $settings.showConfidence)
                CarbonToggle(
                    title: "Burn metadata into captures",
                    caption: "Adds a footer with the source, model and time to the saved image.",
                    isOn: $settings.burnInMetadata
                )
                CarbonToggle(title: "Haptic on capture", isOn: $settings.hapticOnCapture)
            }
        }
    }

    private func connection(settings: AppSettings) -> some View {
        @Bindable var settings = settings
        return CarbonTile {
            VStack(alignment: .leading, spacing: Space.s05) {
                CarbonSectionHeader(
                    title: "FIELD ONE connection",
                    caption: "The camera broadcasts a fixed network name set in its firmware."
                )
                CarbonToggle(
                    title: "Join camera Wi-Fi automatically",
                    caption: "Shows the iOS prompt to join \(FieldOneProduct.factorySSID). "
                        + "Leave off when Wi-Fi is managed outside the app.",
                    isOn: $settings.joinWiFiAutomatically
                )
                VStack(alignment: .leading, spacing: Space.s03) {
                    Text("Camera address")
                        .font(CarbonType.label01())
                        .foregroundStyle(Carbon.textSecondary)
                    TextField("Discover automatically", text: $settings.preferredHost)
                        .font(CarbonType.code02())
                        .foregroundStyle(Carbon.textPrimary)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                        .padding(.horizontal, Space.s05)
                        .frame(height: 48)
                        .background(Carbon.field01)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Carbon.borderStrong01).frame(height: 1)
                        }
                    Text("Leave empty to check the gateway and the known FIELD ONE addresses.")
                        .font(CarbonType.helperText01())
                        .foregroundStyle(Carbon.textHelper)
                }
            }
        }
        .onChange(of: settings.joinWiFiAutomatically) { _, _ in onDetectionSettingsChanged() }
        .onChange(of: settings.preferredHost) { _, _ in onDetectionSettingsChanged() }
    }

    private var about: some View {
        CarbonTile {
            VStack(alignment: .leading, spacing: 0) {
                CarbonSectionHeader(title: "About").padding(.bottom, Space.s03)
                CarbonDataRow(key: "Camera", value: FieldOneProduct.name, monospaced: false)
                CarbonDataRow(key: "SDK", value: FieldOneSDKVersion.current)
                CarbonDataRow(
                    key: "Live stream",
                    value: "\(FieldOneProduct.videoWidth) x \(FieldOneProduct.videoHeight) "
                        + "at \(FieldOneProduct.framesPerSecond) fps"
                )
                CarbonDataRow(key: "Models installed", value: "\(modelStore.models.count)")
                CarbonDataRow(key: "Design system", value: "IBM Carbon, Gray 100", monospaced: false)

                Text(
                    "Capture on stock firmware saves the current live frame. A high-resolution "
                    + "still can only be recovered from a closed camera recording, and the app "
                    + "labels those as recovered rather than live."
                )
                .font(CarbonType.helperText01())
                .foregroundStyle(Carbon.textHelper)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.s05)
            }
        }
    }
}
