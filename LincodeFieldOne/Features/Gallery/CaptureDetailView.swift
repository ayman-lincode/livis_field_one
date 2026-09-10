import SwiftUI

/// One captured frame: the annotated image, the raw image, and what was found.
struct CaptureDetailView: View {
    let capture: CaptureRecord

    @Environment(CaptureStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var showsAnnotated = true
    @State private var isSharing = false
    @State private var status: String?
    @State private var confirmingDelete = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s05) {
                    imagePane
                    if let status {
                        CarbonInlineNotification(
                            kind: .success, title: status, onDismiss: { self.status = nil }
                        )
                    }
                    actions
                    metadata
                    detections
                }
                .padding(Space.s05)
            }
            .background(Carbon.background)
            .navigationTitle("Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.foregroundStyle(Carbon.textPrimary)
                }
            }
            .sheet(isPresented: $isSharing) {
                ShareSheet(items: [store.annotatedURL(for: capture.id)])
            }
            .confirmationDialog(
                "Delete this capture?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    store.delete(capture.id)
                    dismiss()
                }
                Button("Keep", role: .cancel) {}
            }
        }
    }

    private var imagePane: some View {
        VStack(spacing: 0) {
            if let image = store.image(for: capture.id, annotated: showsAnnotated) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .background(Color.black)
            } else {
                Carbon.layer02.frame(height: 200)
            }

            HStack(spacing: 0) {
                toggleTab(title: "With boxes", isOn: showsAnnotated) { showsAnnotated = true }
                toggleTab(title: "Original frame", isOn: !showsAnnotated) { showsAnnotated = false }
            }
        }
        .overlay(Rectangle().strokeBorder(Carbon.borderSubtle00, lineWidth: 1))
    }

    private func toggleTab(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
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

    private var actions: some View {
        HStack(spacing: Space.s03) {
            CarbonButton(title: "Share", systemImage: "square.and.arrow.up", size: .medium) {
                isSharing = true
            }
            CarbonButton(
                title: "Save to Photos", systemImage: "photo.badge.plus",
                kind: .tertiary, size: .medium
            ) {
                Task {
                    do {
                        try await store.exportToPhotoLibrary(capture.id)
                        status = "Saved to your photo library"
                    } catch {
                        status = error.localizedDescription
                    }
                }
            }
            CarbonIconButton(
                systemImage: "trash", accessibilityLabel: "Delete capture", size: 40
            ) { confirmingDelete = true }
        }
    }

    private var metadata: some View {
        CarbonTile {
            VStack(alignment: .leading, spacing: 0) {
                CarbonSectionHeader(title: "Frame").padding(.bottom, Space.s03)
                CarbonDataRow(
                    key: "Captured",
                    value: capture.capturedAt.formatted(date: .abbreviated, time: .standard)
                )
                CarbonDataRow(key: "Source", value: capture.sourceKind.title, monospaced: false)
                CarbonDataRow(key: "Model", value: capture.modelName, monospaced: false)
                CarbonDataRow(
                    key: "Resolution", value: "\(capture.frameWidth) x \(capture.frameHeight)"
                )
                CarbonDataRow(
                    key: "Provenance",
                    value: capture.isRecoveredRecordingFrame
                        ? "Recovered recording frame"
                        : "Live frame",
                    valueColor: capture.isRecoveredRecordingFrame
                        ? Carbon.supportWarning
                        : Carbon.textPrimary,
                    monospaced: false
                )
            }
        }
    }

    private var detections: some View {
        CarbonTile {
            VStack(alignment: .leading, spacing: Space.s04) {
                HStack {
                    CarbonSectionHeader(title: "Detections")
                    Spacer()
                    CarbonTag(text: "\(capture.detections.count)", kind: .outline)
                }
                if capture.detections.isEmpty {
                    Text("Nothing was above the confidence threshold in this frame.")
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
}
