import SwiftUI

/// Every frame the operator captured, newest first.
struct GalleryView: View {
    @Environment(CaptureStore.self) private var store

    @State private var selected: CaptureRecord?
    @State private var exportURL: URL?
    @State private var confirmingClear = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 1)]

    var body: some View {
        VStack(spacing: 0) {
            CarbonPageHeader(
                title: "Captures",
                subtitle: store.captures.isEmpty
                    ? "Nothing captured yet"
                    : "\(store.captures.count) frame\(store.captures.count == 1 ? "" : "s") on this device"
            ) {
                if !store.captures.isEmpty {
                    HStack(spacing: Space.s03) {
                        CarbonButton(
                            title: "Export", systemImage: "square.and.arrow.up",
                            kind: .tertiary, size: .medium, fullWidth: false
                        ) {
                            exportURL = try? store.exportBundle()
                        }
                        CarbonIconButton(
                            systemImage: "trash", accessibilityLabel: "Delete all captures", size: 40
                        ) { confirmingClear = true }
                    }
                }
            }

            if store.captures.isEmpty {
                VStack {
                    Spacer()
                    CarbonEmptyState(
                        systemImage: "square.grid.2x2",
                        title: "No captures",
                        message: "Press the shutter on the live view to save a frame with its "
                            + "detection boxes burnt in."
                    )
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 1) {
                        ForEach(store.captures) { capture in
                            CaptureThumbnail(capture: capture) { selected = capture }
                        }
                    }
                    .padding(1)
                }
            }
        }
        .background(Carbon.background)
        .sheet(item: $selected) { capture in
            CaptureDetailView(capture: capture)
        }
        .sheet(isPresented: Binding(
            get: { exportURL != nil },
            set: { if !$0 { exportURL = nil } }
        )) {
            if let exportURL {
                ShareSheet(items: [exportURL])
            }
        }
        .confirmationDialog(
            "Delete every capture?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Delete all", role: .destructive) { store.deleteAll() }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("This removes the annotated frames and their detection records from this device.")
        }
    }
}

private struct CaptureThumbnail: View {
    let capture: CaptureRecord
    let action: () -> Void

    @Environment(CaptureStore.self) private var store

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                if let image = store.image(for: capture.id) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Carbon.layer02
                }

                LinearGradient(
                    colors: [.clear, Carbon.background.opacity(0.9)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: Space.s01) {
                    Text(capture.capturedAt.formatted(date: .omitted, time: .standard))
                        .font(CarbonType.code01())
                        .foregroundStyle(Carbon.textPrimary)
                    Text(capture.summary)
                        .font(.system(size: 10))
                        .foregroundStyle(Carbon.textSecondary)
                        .lineLimit(1)
                }
                .padding(Space.s03)
            }
            .frame(height: 150)
            .clipped()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// UIKit share sheet, used for exporting captures.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
