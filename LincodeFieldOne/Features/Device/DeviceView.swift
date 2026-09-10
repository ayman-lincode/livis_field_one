import FieldOneSDK
import SwiftUI

/// What the connected FIELD ONE reports about itself.
///
/// Everything here comes from the camera at runtime. Absent fields are shown as
/// unknown rather than zero, because the SDK treats them that way.
struct DeviceView: View {
    let source: FieldOneFrameSource?

    @State private var identity: FieldOneDeviceIdentity?
    @State private var battery: FieldOneBatteryStatus?
    @State private var storage: FieldOneStorageStatus?
    @State private var capabilities: FieldOneDeviceCapabilities?
    @State private var health: FieldOneHealth?
    @State private var isLoading = false
    @State private var error: String?

    private var isConnected: Bool { source?.deviceControl != nil }

    var body: some View {
        VStack(spacing: 0) {
            CarbonPageHeader(
                title: "Device",
                subtitle: FieldOneProduct.name,
                showsLockup: false
            ) {
                CarbonIconButton(
                    systemImage: "arrow.clockwise",
                    accessibilityLabel: "Refresh device status",
                    size: 40,
                    isEnabled: isConnected && !isLoading
                ) { Task { await refresh() } }
            }

            ScrollView {
                VStack(spacing: Space.s05) {
                    if let error {
                        CarbonInlineNotification(
                            kind: .warning, title: "Could not read the camera",
                            message: error, onDismiss: { self.error = nil }
                        )
                    }

                    if !isConnected {
                        CarbonEmptyState(
                            systemImage: "antenna.radiowaves.left.and.right.slash",
                            title: "Camera not connected",
                            message: "Connect FIELD ONE on the live view. Battery, storage and "
                                + "firmware capabilities are read from the camera itself."
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, Space.s08)
                    } else {
                        if let battery { batteryTile(battery) }
                        if let storage { storageTile(storage) }
                        if let identity { identityTile(identity) }
                        if let capabilities { capabilityTile(capabilities) }
                        linkTile
                        captureBoundary
                    }
                }
                .padding(Space.s05)
            }
        }
        .background(Carbon.background)
        .task { if isConnected { await refresh() } }
    }

    // MARK: - Tiles

    private func batteryTile(_ battery: FieldOneBatteryStatus) -> some View {
        CarbonTile {
            VStack(alignment: .leading, spacing: Space.s04) {
                HStack {
                    CarbonSectionHeader(title: "Battery")
                    Spacer()
                    if battery.low {
                        CarbonTag(text: "LOW", kind: .red, systemImage: "exclamationmark.triangle.fill")
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: Space.s03) {
                    Text(battery.percent.map { "\($0)" } ?? "--")
                        .font(CarbonType.heading05())
                        .foregroundStyle(battery.low ? Carbon.supportError : Carbon.textPrimary)
                    Text("%")
                        .font(CarbonType.body01())
                        .foregroundStyle(Carbon.textHelper)
                    Spacer()
                    Text("reported in steps of \(battery.granularityPercent)")
                        .font(CarbonType.helperText01())
                        .foregroundStyle(Carbon.textHelper)
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Carbon.layer03).frame(height: 6)
                        Rectangle()
                            .fill(battery.low ? Carbon.supportError : Carbon.supportSuccess)
                            .frame(
                                width: geometry.size.width * CGFloat(battery.percent ?? 0) / 100,
                                height: 6
                            )
                    }
                }
                .frame(height: 6)

                if let advice = battery.advice {
                    Text(advice)
                        .font(CarbonType.helperText01())
                        .foregroundStyle(Carbon.supportWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let charging = battery.charging {
                    CarbonDataRow(key: "Charging", value: charging ? "Yes" : "No", monospaced: false)
                }
                if let temperature = battery.temperatureCelsius {
                    CarbonDataRow(key: "Temperature", value: String(format: "%.1f C", temperature))
                }
            }
        }
    }

    private func storageTile(_ storage: FieldOneStorageStatus) -> some View {
        CarbonTile {
            VStack(alignment: .leading, spacing: Space.s04) {
                CarbonSectionHeader(title: "Storage")
                if !storage.usable {
                    Text("No usable card in the camera.")
                        .font(CarbonType.bodyCompact01())
                        .foregroundStyle(Carbon.supportWarning)
                } else {
                    let used = storage.totalCapacityBytes - storage.totalFreeBytes
                    let fraction = storage.totalCapacityBytes > 0
                        ? Double(used) / Double(storage.totalCapacityBytes)
                        : 0
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Carbon.layer03).frame(height: 6)
                            Rectangle()
                                .fill(fraction > 0.9 ? Carbon.supportWarning : Carbon.supportInfo)
                                .frame(width: geometry.size.width * fraction, height: 6)
                        }
                    }
                    .frame(height: 6)

                    CarbonDataRow(key: "Free", value: bytes(storage.totalFreeBytes))
                    CarbonDataRow(key: "Capacity", value: bytes(storage.totalCapacityBytes))
                    ForEach(storage.volumes, id: \.id) { volume in
                        CarbonDataRow(
                            key: volume.label ?? "Volume \(volume.id)",
                            value: "\(bytes(volume.freeSpaceBytes)) free"
                        )
                    }
                }
            }
        }
    }

    private func identityTile(_ identity: FieldOneDeviceIdentity) -> some View {
        CarbonTile {
            VStack(alignment: .leading, spacing: 0) {
                CarbonSectionHeader(title: "Identity").padding(.bottom, Space.s03)
                CarbonDataRow(key: "Manufacturer", value: identity.manufacturer ?? "unknown")
                CarbonDataRow(key: "Model", value: identity.model ?? "unknown")
                CarbonDataRow(key: "Firmware", value: identity.firmwareVersion ?? "unknown")
                CarbonDataRow(key: "Serial", value: identity.serialNumber ?? "unknown")
                if let ssid = identity.wifiSSID {
                    CarbonDataRow(key: "Wi-Fi name", value: ssid)
                }
                if let unit = identity.unitId {
                    CarbonDataRow(key: "Unit", value: unit)
                }
                CarbonDataRow(key: "Operations", value: "\(identity.operations.count)")
                CarbonDataRow(key: "Properties", value: "\(identity.properties.count)")
            }
        }
    }

    private func capabilityTile(_ capabilities: FieldOneDeviceCapabilities) -> some View {
        CarbonTile {
            VStack(alignment: .leading, spacing: Space.s04) {
                CarbonSectionHeader(
                    title: "Firmware capabilities",
                    caption: "Read from the connected camera, not assumed."
                )
                VStack(spacing: 0) {
                    CapabilityRow(title: "Live preview", isOn: capabilities.livePreview)
                    CapabilityRow(title: "Preview snapshot", isOn: capabilities.previewSnapshot)
                    CapabilityRow(
                        title: "Present-moment camera JPEG",
                        isOn: capabilities.presentMomentCameraJPEG
                    )
                    CapabilityRow(
                        title: "Recording frame extraction",
                        isOn: capabilities.deferredRecordingFrame
                    )
                    CapabilityRow(title: "Card recording", isOn: capabilities.cardRecording)
                    CapabilityRow(
                        title: "Remote recording control",
                        isOn: capabilities.remoteRecordingControl
                    )
                    CapabilityRow(title: "Media listing", isOn: capabilities.mediaListing)
                    CapabilityRow(title: "Resumable download", isOn: capabilities.resumableDownload)
                    CapabilityRow(title: "Live audio", isOn: capabilities.liveAudio)
                }
            }
        }
    }

    private var linkTile: some View {
        CarbonTile {
            VStack(alignment: .leading, spacing: 0) {
                CarbonSectionHeader(title: "Link").padding(.bottom, Space.s03)
                CarbonDataRow(key: "Address", value: health?.host ?? "unknown")
                CarbonDataRow(
                    key: "RTSP reachable",
                    value: (health?.rtspReachable ?? false) ? "Yes" : "No",
                    valueColor: (health?.rtspReachable ?? false)
                        ? Carbon.supportSuccess : Carbon.supportError,
                    monospaced: false
                )
                if let checkedAt = health?.checkedAt {
                    CarbonDataRow(
                        key: "Checked", value: checkedAt.formatted(date: .omitted, time: .standard)
                    )
                }
            }
        }
    }

    private var captureBoundary: some View {
        CarbonTile(layer: Carbon.layer02) {
            VStack(alignment: .leading, spacing: Space.s03) {
                CarbonSectionHeader(title: "Capture boundary")
                Text(
                    "The shutter saves the current live frame at "
                    + "\(FieldOneProduct.videoWidth) x \(FieldOneProduct.videoHeight). "
                    + "A \(FieldOneProduct.recordingWidth) x \(FieldOneProduct.recordingHeight) "
                    + "still can only be pulled from a closed recording on the card, and is not "
                    + "a present-moment shutter. This app labels those separately so a recovered "
                    + "frame is never presented as live evidence."
                )
                .font(CarbonType.helperText01())
                .foregroundStyle(Carbon.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Loading

    private func refresh() async {
        guard let control = source?.deviceControl else { return }
        isLoading = true
        defer { isLoading = false }

        health = await source?.health()

        do {
            battery = try await control.getBatteryStatus()
        } catch { self.error = error.localizedDescription }
        do {
            storage = try await control.getStorageStatus()
        } catch { if self.error == nil { self.error = error.localizedDescription } }
        identity = try? await control.getDeviceInfo()
        capabilities = try? await control.getCapabilities()
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }
}

private struct CapabilityRow: View {
    let title: String
    let isOn: Bool

    var body: some View {
        HStack(spacing: Space.s04) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "minus.circle")
                .font(.system(size: 15))
                .foregroundStyle(isOn ? Carbon.supportSuccess : Carbon.textPlaceholder)
            Text(title)
                .font(CarbonType.bodyCompact01())
                .foregroundStyle(isOn ? Carbon.textPrimary : Carbon.textHelper)
            Spacer()
            Text(isOn ? "available" : "not advertised")
                .font(CarbonType.helperText01())
                .foregroundStyle(Carbon.textHelper)
        }
        .padding(.vertical, Space.s03)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Carbon.borderSubtle00).frame(height: 1)
        }
    }
}
