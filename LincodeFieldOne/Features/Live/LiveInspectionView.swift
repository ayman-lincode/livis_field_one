import SwiftUI

/// The inspection screen: live video, boxes over it, and the shutter.
struct LiveInspectionView: View {
    @Bindable var model: LiveViewModel
    var openModels: () -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(ModelStore.self) private var modelStore
    @Environment(CaptureStore.self) private var captureStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var showsDetectionList = false
    @State private var showsSourcePicker = false

    var body: some View {
        VStack(spacing: 0) {
            statusBar

            ZStack {
                Carbon.background

                VideoPreview(source: model.source)
                    .ignoresSafeArea(edges: .horizontal)

                DetectionOverlay(
                    detections: model.isInferenceEnabled ? model.result.detections : [],
                    frameSize: model.frameSize ?? model.source.displaySize,
                    showLabels: settings.showLabels,
                    showConfidence: settings.showConfidence,
                    showsFrameGuide: model.state.isStreaming
                )

                if !model.state.isStreaming {
                    connectionCurtain
                }

                if model.state.isStreaming {
                    VStack {
                        HStack(alignment: .top) {
                            telemetry
                            Spacer()
                            if model.isInferenceEnabled { modelChip }
                        }
                        .padding(Space.s05)
                        Spacer()
                    }
                }

                if let stage = model.captureStage {
                    CaptureProgressOverlay(stage: stage)
                        .transition(.opacity)
                }

                if let banner = model.banner {
                    VStack {
                        Spacer()
                        CarbonInlineNotification(
                            kind: banner.kind,
                            title: banner.title,
                            message: banner.message,
                            onDismiss: { model.banner = nil }
                        )
                        .padding(Space.s05)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            if showsDetectionList { detectionList }

            controlBar
        }
        .background(Carbon.background)
        .animation(CarbonMotion.expressive, value: model.banner)
        .animation(CarbonMotion.productive, value: model.captureStage)
        .fullScreenCover(item: $model.reviewCapture) { capture in
            CaptureDetailView(capture: capture, isFreshCapture: true)
                .environment(captureStore)
                .environment(settings)
        }
        .animation(CarbonMotion.productive, value: showsDetectionList)
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in
            // The SDK asks that video be stopped before leaving, and that the
            // link be re-established rather than assumed on return.
            switch phase {
            case .background: model.stop()
            case .active: if case .idle = model.state { Task { await model.start() } }
            default: break
            }
        }
        .onChange(of: model.banner?.id) { _, _ in
            guard model.banner != nil else { return }
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                model.banner = nil
            }
        }
        .confirmationDialog("Video source", isPresented: $showsSourcePicker, titleVisibility: .visible) {
            ForEach(FrameSourceKind.allCases) { kind in
                Button(kind.title) { Task { await model.switchSource(to: kind) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose where live frames come from.")
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: Space.s04) {
            ProductLockup(logoHeight: 18)
            Spacer(minLength: Space.s04)
            CarbonTag(
                text: stateTagText,
                kind: stateTagKind,
                systemImage: model.sourceKind.systemImage
            )
        }
        .padding(.horizontal, Space.s05)
        .padding(.vertical, Space.s04)
        .background(Carbon.layer01.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Carbon.borderSubtle00).frame(height: 1)
        }
    }

    /// Kept to two words so the lockup beside it never has to wrap.
    private var stateTagText: String {
        switch model.state {
        case .streaming: "LIVE"
        case .preparing: "CONNECTING"
        case .failed: "FAILED"
        case .idle: "OFFLINE"
        }
    }

    private var stateTagKind: CarbonTagKind {
        switch model.state {
        case .streaming: .green
        case .preparing: .blue
        case .failed: .red
        case .idle: .outline
        }
    }

    // MARK: - Overlays

    private var connectionCurtain: some View {
        VStack(spacing: Space.s05) {
            Spacer(minLength: 0)
            switch model.state {
            case .idle:
                CarbonEmptyState(
                    systemImage: model.sourceKind.systemImage,
                    title: "No live video",
                    message: model.sourceKind == .fieldOne
                        ? "Put the phone on the FIELD ONE Wi-Fi, then connect."
                        : "Allow camera access, then start the camera.",
                    actionTitle: "Connect",
                    action: { Task { await model.start() } }
                )
            case .preparing(let step):
                VStack(spacing: Space.s05) {
                    ProgressView().tint(Carbon.textPrimary)
                    Text(step)
                        .font(CarbonType.body01())
                        .foregroundStyle(Carbon.textSecondary)
                }
            case .failed(let message):
                VStack(spacing: Space.s05) {
                    CarbonInlineNotification(
                        kind: .error, title: "Could not start video", message: message
                    )
                    HStack(spacing: Space.s03) {
                        CarbonButton(title: "Retry", systemImage: "arrow.clockwise", fullWidth: false) {
                            Task { await model.start() }
                        }
                        CarbonButton(
                            title: "Use this iPhone", systemImage: "iphone",
                            kind: .tertiary, fullWidth: false
                        ) {
                            Task { await model.switchSource(to: .deviceCamera) }
                        }
                    }
                }
                .padding(Space.s05)
                .frame(maxWidth: 520)
                .fixedSize(horizontal: false, vertical: true)
            case .streaming:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Carbon.background.opacity(0.94))
    }

    private var telemetry: some View {
        VStack(alignment: .leading, spacing: Space.s02) {
            TelemetryRow(
                key: "FPS",
                value: model.isInferenceEnabled
                    ? String(format: "%.1f", model.stats.framesPerSecond)
                    : "--"
            )
            TelemetryRow(
                key: "LATENCY",
                value: model.isInferenceEnabled
                    ? "\(Int(model.stats.averageMilliseconds.rounded())) ms"
                    : "--"
            )
            TelemetryRow(key: "OBJECTS", value: "\(model.result.detections.count)")
            if let size = model.source.displaySize ?? model.frameSize {
                TelemetryRow(key: "FRAME", value: "\(Int(size.width))x\(Int(size.height))")
            }
        }
        .padding(Space.s04)
        .background(Carbon.background.opacity(0.72))
        .overlay(Rectangle().strokeBorder(Carbon.borderSubtle01.opacity(0.6), lineWidth: 1))
    }

    private var modelChip: some View {
        Button(action: openModels) {
            HStack(spacing: Space.s03) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 13))
                VStack(alignment: .leading, spacing: 0) {
                    Text(modelStore.selectedModel?.displayName ?? "No model")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(
                        modelStore.selectedModel.map { "\($0.labels.count) classes" }
                            ?? "Tap to import"
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(Carbon.textHelper)
                }
            }
            .foregroundStyle(Carbon.textPrimary)
            .padding(.horizontal, Space.s04)
            .padding(.vertical, Space.s03)
            .background(Carbon.background.opacity(0.72))
            .overlay(Rectangle().strokeBorder(Carbon.borderSubtle01.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 200)
    }

    // MARK: - Detection list

    private var detectionList: some View {
        VStack(spacing: 0) {
            HStack {
                CarbonSectionHeader(title: "Detections in this frame")
                Spacer()
                Text("\(model.result.detections.count)")
                    .font(CarbonType.metric())
                    .foregroundStyle(Carbon.textSecondary)
            }
            .padding(.horizontal, Space.s05)
            .padding(.top, Space.s04)

            if model.result.detections.isEmpty {
                Text(
                    model.isInferenceEnabled
                        ? "Nothing above the confidence threshold."
                        : "Inference is paused."
                )
                .font(CarbonType.bodyCompact01())
                .foregroundStyle(Carbon.textHelper)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.s05)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(model.result.detections) { detection in
                            HStack(spacing: Space.s04) {
                                Rectangle()
                                    .fill(detection.color)
                                    .frame(width: 3, height: 24)
                                Text(detection.label)
                                    .font(CarbonType.bodyCompact01())
                                    .foregroundStyle(Carbon.textPrimary)
                                Spacer()
                                Text(detection.confidencePercent)
                                    .font(CarbonType.code01())
                                    .foregroundStyle(Carbon.textSecondary)
                            }
                            .padding(.horizontal, Space.s05)
                            .padding(.vertical, Space.s03)
                            .background(Carbon.layer01)
                        }
                    }
                }
                .frame(maxHeight: 168)
            }
        }
        .background(Carbon.layer01)
        .overlay(alignment: .top) {
            Rectangle().fill(Carbon.borderSubtle00).frame(height: 1)
        }
    }

    // MARK: - Controls

    private var controlBar: some View {
        VStack(spacing: 0) {
            if let error = model.detectorError {
                CarbonInlineNotification(kind: .warning, title: "Inference stopped", message: error)
            }

            HStack(spacing: Space.s03) {
                CarbonIconButton(
                    systemImage: model.sourceKind.systemImage,
                    accessibilityLabel: "Change video source",
                    isEnabled: !model.isCapturing,
                    isSelected: false
                ) { showsSourcePicker = true }

                CarbonIconButton(
                    systemImage: model.isInferenceEnabled ? "pause.fill" : "play.fill",
                    accessibilityLabel: model.isInferenceEnabled ? "Pause inference" : "Resume inference",
                    isEnabled: modelStore.selectedModel != nil
                ) { model.isInferenceEnabled.toggle() }

                Spacer(minLength: 0)

                ShutterButton(
                    isBusy: model.isCapturing,
                    isEnabled: model.state.isStreaming,
                    mode: model.shutterMode
                ) { model.capture() }

                Spacer(minLength: 0)

                CarbonIconButton(
                    systemImage: "list.bullet.rectangle",
                    accessibilityLabel: "Show detections",
                    isSelected: showsDetectionList
                ) { showsDetectionList.toggle() }

                lastCaptureThumbnail
            }
            .padding(.horizontal, Space.s05)
            .padding(.vertical, Space.s04)
        }
        .background(Carbon.layer01)
        .overlay(alignment: .top) {
            Rectangle().fill(Carbon.borderSubtle00).frame(height: 1)
        }
    }

    private var lastCaptureThumbnail: some View {
        Group {
            if let capture = model.lastCapture ?? captureStore.captures.first,
               let image = captureStore.thumbnail(for: capture.id) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipped()
                    .overlay(Rectangle().strokeBorder(Carbon.borderStrong01, lineWidth: 1))
            } else {
                Rectangle()
                    .fill(Carbon.layer02)
                    .frame(width: 48, height: 48)
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 15))
                            .foregroundStyle(Carbon.textPlaceholder)
                    )
                    .overlay(Rectangle().strokeBorder(Carbon.borderSubtle01, lineWidth: 1))
            }
        }
        .accessibilityLabel("Most recent capture")
    }
}

private struct TelemetryRow: View {
    let key: String
    let value: String

    var body: some View {
        HStack(spacing: Space.s04) {
            Text(key)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Carbon.textHelper)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(CarbonType.metric())
                .foregroundStyle(Carbon.textPrimary)
        }
    }
}

/// The capture control. Square-in-circle, so it reads as a shutter without
/// borrowing the rounded language Carbon avoids everywhere else.
private struct ShutterButton: View {
    let isBusy: Bool
    let isEnabled: Bool
    let mode: LiveViewModel.ShutterMode
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(isEnabled ? Carbon.textPrimary : Carbon.buttonDisabled, lineWidth: 2)
                    .frame(width: 62, height: 62)
                Rectangle()
                    .fill(isEnabled ? LincodeBrand.red : Carbon.buttonDisabled)
                    .frame(width: isPressed ? 34 : 44, height: isPressed ? 34 : 44)
                if isBusy {
                    ProgressView().tint(.white)
                }
            }
            .contentShape(Circle())
        }
        .overlay(alignment: .bottom) {
            Text(caption)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(mode == .cameraPhoto ? Carbon.textPrimary : Carbon.textHelper)
                .fixedSize()
                .offset(y: 13)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isBusy)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .animation(CarbonMotion.productive, value: isPressed)
        .accessibilityLabel(mode == .cameraPhoto ? "Take camera photo" : "Capture live frame")
    }

    private var caption: String {
        switch mode {
        case .cameraPhoto: "PHOTO"
        case .liveFrame: "FRAME"
        case .unavailable: ""
        }
    }
}

/// Full-bleed status while the camera takes, downloads and analyses a still.
private struct CaptureProgressOverlay: View {
    let stage: LiveViewModel.CaptureStage

    var body: some View {
        VStack(spacing: Space.s05) {
            Spacer()
            VStack(alignment: .leading, spacing: Space.s04) {
                HStack(spacing: Space.s04) {
                    ProgressView().tint(Carbon.textPrimary)
                    Text(stage.title)
                        .font(CarbonType.heading02())
                        .foregroundStyle(Carbon.textPrimary)
                        .contentTransition(.numericText())
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Carbon.layer03).frame(height: 2)
                        Rectangle()
                            .fill(LincodeBrand.red)
                            .frame(width: geometry.size.width * (stage.fraction ?? 0), height: 2)
                    }
                }
                .frame(height: 2)
                .opacity(stage.fraction == nil ? 0 : 1)
                Text("Keep the camera steady. The shutter will not fire twice.")
                    .font(CarbonType.helperText01())
                    .foregroundStyle(Carbon.textHelper)
            }
            .padding(Space.s05)
            .frame(maxWidth: 420)
            .background(Carbon.layer01)
            .overlay(Rectangle().strokeBorder(Carbon.borderSubtle01, lineWidth: 1))
            .padding(Space.s05)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Carbon.background.opacity(0.55))
        .allowsHitTesting(true)
    }
}
