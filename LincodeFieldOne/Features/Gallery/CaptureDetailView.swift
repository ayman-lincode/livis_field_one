import SwiftUI

/// Review of one captured still: the full image with the model's boxes over
/// it, zoomable, plus everything recorded about how it was taken.
///
/// Boxes are drawn live over the original image rather than shown from the
/// burnt-in file, so they stay sharp at any zoom on a 12 MP camera photo.
struct CaptureDetailView: View {
    let capture: CaptureRecord
    /// True when presented straight after the shutter, rather than from Captures.
    var isFreshCapture: Bool = false

    @Environment(CaptureStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var showsBoxes = true
    @State private var shareURL: URL?
    @State private var status: (kind: CarbonNotificationKind, text: String)?
    @State private var confirmingDelete = false

    private var detections: [Detection] {
        capture.detections.map(\.detection)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ZoomableDetectionImage(
                image: store.image(for: capture.id, annotated: false),
                frameSize: capture.frameSize,
                detections: showsBoxes ? detections : []
            )
            .frame(maxWidth: .infinity)
            .frame(minHeight: 260, maxHeight: .infinity)
            .background(Color.black)

            layerTabs

            ScrollView {
                VStack(alignment: .leading, spacing: Space.s05) {
                    if let status {
                        CarbonInlineNotification(
                            kind: status.kind, title: status.text, onDismiss: { self.status = nil }
                        )
                    }
                    detectionsTile
                    frameTile
                    if let camera = capture.camera { cameraTile(camera) }
                    actions
                }
                .padding(Space.s05)
            }
            .frame(maxHeight: 340)
            .background(Carbon.background)
        }
        .background(Carbon.background.ignoresSafeArea())
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let shareURL { ShareSheet(items: [shareURL]) }
        }
        .confirmationDialog("Delete this capture?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.delete(capture.id)
                dismiss()
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The image, its original and its detection record are removed from this device.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Space.s04) {
            VStack(alignment: .leading, spacing: Space.s01) {
                Text(isFreshCapture ? "Captured" : "Capture")
                    .font(CarbonType.heading02())
                    .foregroundStyle(Carbon.textPrimary)
                Text(headline)
                    .font(CarbonType.helperText01())
                    .foregroundStyle(Carbon.textHelper)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.s03)
            CarbonTag(
                text: "\(capture.detections.count) found",
                kind: capture.detections.isEmpty ? .outline : .green
            )
            CarbonButton(
                title: isFreshCapture ? "Done" : "Close",
                kind: .tertiary, size: .small, fullWidth: false
            ) { dismiss() }
        }
        .padding(.horizontal, Space.s05)
        .padding(.vertical, Space.s04)
        .background(Carbon.layer01.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Carbon.borderSubtle00).frame(height: 1)
        }
    }

    private var headline: String {
        var parts = [capture.provenance.title, capture.resolutionText]
        if let camera = capture.camera { parts.append(camera.megapixelsText) }
        return parts.joined(separator: "  |  ")
    }

    private var layerTabs: some View {
        HStack(spacing: 0) {
            tab(title: "With boxes", isOn: showsBoxes) { showsBoxes = true }
            tab(title: "Original", isOn: !showsBoxes) { showsBoxes = false }
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Carbon.borderSubtle00).frame(height: 1)
        }
    }

    private func tab(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(CarbonType.bodyCompact01())
                .foregroundStyle(isOn ? Carbon.textPrimary : Carbon.textPlaceholder)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(isOn ? Carbon.layer02 : Carbon.layer01)
                .overlay(alignment: .top) {
                    Rectangle().fill(isOn ? LincodeBrand.red : .clear).frame(height: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tiles

    private var detectionsTile: some View {
        CarbonTile {
            VStack(alignment: .leading, spacing: Space.s04) {
                HStack {
                    CarbonSectionHeader(
                        title: "Detections",
                        caption: capture.inferenceMilliseconds.map {
                            "Model ran on the full \(capture.resolutionText) still in \(Int($0.rounded())) ms."
                        }
                    )
                    Spacer()
                    CarbonTag(text: "\(capture.detections.count)", kind: .outline)
                }
                if capture.detections.isEmpty {
                    Text("Nothing was above the confidence threshold in this still.")
                        .font(CarbonType.helperText01())
                        .foregroundStyle(Carbon.textHelper)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(capture.detections.enumerated()), id: \.offset) { _, stored in
                            HStack(spacing: Space.s04) {
                                Rectangle()
                                    .fill(Carbon.categoricalColor(for: stored.classIndex))
                                    .frame(width: 3, height: 20)
                                Text(stored.label)
                                    .font(CarbonType.bodyCompact01())
                                    .foregroundStyle(Carbon.textPrimary)
                                Spacer()
                                Text("\(Int((stored.confidence * 100).rounded()))%")
                                    .font(CarbonType.code01())
                                    .foregroundStyle(Carbon.textSecondary)
                            }
                            .padding(.vertical, Space.s03)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(Carbon.borderSubtle00).frame(height: 1)
                            }
                        }
                    }
                }
            }
        }
    }

    private var frameTile: some View {
        CarbonTile {
            VStack(alignment: .leading, spacing: 0) {
                CarbonSectionHeader(title: "Still").padding(.bottom, Space.s03)
                CarbonDataRow(
                    key: "Captured",
                    value: capture.capturedAt.formatted(date: .abbreviated, time: .standard)
                )
                CarbonDataRow(
                    key: "Provenance",
                    value: capture.provenance.title,
                    valueColor: capture.provenance == .cameraPhoto ? Carbon.supportSuccess : Carbon.supportWarning,
                    monospaced: false
                )
                CarbonDataRow(key: "Source", value: capture.sourceKind.title, monospaced: false)
                CarbonDataRow(key: "Resolution", value: capture.resolutionText)
                CarbonDataRow(key: "Model", value: capture.modelName, monospaced: false)
            }
        }
    }

    private func cameraTile(_ camera: CameraPhotoMetadata) -> some View {
        CarbonTile {
            VStack(alignment: .leading, spacing: 0) {
                CarbonSectionHeader(
                    title: "Camera photo",
                    caption: "The original is the camera's JPEG, stored unmodified."
                )
                .padding(.bottom, Space.s03)
                CarbonDataRow(key: "File on card", value: camera.filename)
                CarbonDataRow(key: "Handle", value: String(format: "0x%08X", camera.handle))
                CarbonDataRow(
                    key: "JPEG size",
                    value: ByteCountFormatter.string(fromByteCount: Int64(camera.byteCount), countStyle: .file)
                )
                CarbonDataRow(key: "Megapixels", value: camera.megapixelsText)
                CarbonDataRow(
                    key: "Shutter to download",
                    value: String(format: "%.1f s", camera.latencyMs / 1000)
                )
                if let at = camera.deviceCapturedAt {
                    CarbonDataRow(key: "Camera clock", value: at.formatted(date: .abbreviated, time: .standard))
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: Space.s03) {
            Menu {
                Button("Image with boxes") { shareURL = store.annotatedURL(for: capture.id) }
                Button("Original image") { shareURL = store.originalURL(for: capture.id) }
                Button("Detection record (JSON)") { shareURL = store.recordURL(for: capture.id) }
            } label: {
                HStack {
                    Text("Share").font(CarbonType.bodyCompact01())
                    Spacer()
                    Image(systemName: "square.and.arrow.up")
                }
                .padding(.horizontal, Space.s05)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .foregroundStyle(Carbon.textOnColor)
                .background(Carbon.buttonPrimary)
            }

            CarbonButton(
                title: "Save to Photos", systemImage: "photo.badge.plus",
                kind: .tertiary, size: .medium
            ) {
                Task {
                    do {
                        try await store.exportToPhotoLibrary(capture.id, annotated: showsBoxes)
                        status = (.success, showsBoxes ? "Saved with boxes to Photos" : "Saved original to Photos")
                    } catch {
                        status = (.error, error.localizedDescription)
                    }
                }
            }

            CarbonIconButton(
                systemImage: "trash", accessibilityLabel: "Delete capture", size: 40
            ) { confirmingDelete = true }
        }
    }
}

/// An image that pinches, pans and double-taps, with detection boxes pinned
/// to the image so they move and scale with it.
struct ZoomableDetectionImage: View {
    let image: UIImage?
    let frameSize: CGSize
    let detections: [Detection]

    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    private let maximumScale: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    ProgressView().tint(Carbon.textPrimary)
                }

                DetectionOverlay(
                    detections: detections,
                    frameSize: frameSize,
                    showLabels: true,
                    showConfidence: true,
                    showsFrameGuide: false
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .scaleEffect(scale)
            .offset(offset)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = min(maximumScale, max(1, committedScale * value))
                        }
                        .onEnded { _ in
                            committedScale = scale
                            clamp(in: geometry.size)
                        },
                    DragGesture()
                        .onChanged { value in
                            guard scale > 1 else { return }
                            offset = CGSize(
                                width: committedOffset.width + value.translation.width,
                                height: committedOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in clamp(in: geometry.size) }
                )
            )
            .onTapGesture(count: 2) {
                withAnimation(CarbonMotion.expressive) {
                    if scale > 1 {
                        scale = 1; committedScale = 1
                        offset = .zero; committedOffset = .zero
                    } else {
                        scale = 3; committedScale = 3
                    }
                }
            }
            .clipped()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Captured image with \(detections.count) detection boxes")
    }

    /// Keeps the zoomed image covering the viewport instead of drifting off it.
    private func clamp(in size: CGSize) {
        let limitX = size.width * (scale - 1) / 2
        let limitY = size.height * (scale - 1) / 2
        withAnimation(CarbonMotion.productive) {
            offset = CGSize(
                width: min(limitX, max(-limitX, offset.width)),
                height: min(limitY, max(-limitY, offset.height))
            )
        }
        committedOffset = offset
    }
}
