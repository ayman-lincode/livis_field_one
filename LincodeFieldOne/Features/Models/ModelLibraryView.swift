import SwiftUI
import UniformTypeIdentifiers

/// Import, inspect and choose the model used for live inference.
struct ModelLibraryView: View {
    @Environment(ModelStore.self) private var store

    @State private var showsModelImporter = false
    @State private var labelTargetID: UUID?
    @State private var importError: String?
    @State private var inspecting: StoredModel?

    var body: some View {
        VStack(spacing: 0) {
            CarbonPageHeader(
                title: "Models",
                subtitle: "Core ML object detectors on this device"
            ) {
                CarbonButton(
                    title: "Import",
                    systemImage: "plus",
                    size: .medium,
                    fullWidth: false,
                    isBusy: store.isImporting
                ) { showsModelImporter = true }
            }

            ScrollView {
                VStack(spacing: Space.s05) {
                    if let importError {
                        CarbonInlineNotification(
                            kind: .error,
                            title: "Import failed",
                            message: importError,
                            onDismiss: { self.importError = nil }
                        )
                    }

                    if store.models.isEmpty {
                        CarbonEmptyState(
                            systemImage: "cube.transparent",
                            title: "No models yet",
                            message: "Import a .mlmodel, .mlpackage or .mlmodelc object detector. "
                                + "Class names come from the model when it carries them, or from a "
                                + "label file you add afterwards.",
                            actionTitle: "Import a model",
                            action: { showsModelImporter = true }
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, Space.s09)
                    } else {
                        VStack(spacing: Space.s03) {
                            ForEach(store.models) { model in
                                ModelRow(
                                    model: model,
                                    isSelected: store.selectedModelID == model.id,
                                    onSelect: { store.select(model.id) },
                                    onInspect: { inspecting = model },
                                    onAddLabels: { labelTargetID = model.id },
                                    onDelete: { store.delete(model.id) }
                                )
                            }
                        }
                    }

                    supportedFormats
                }
                .padding(Space.s05)
            }
        }
        .background(Carbon.background)
        .fileImporter(
            isPresented: $showsModelImporter,
            allowedContentTypes: [.coreMLModel, .coreMLPackage, .coreMLCompiled, .package, .data],
            allowsMultipleSelection: false
        ) { result in
            handleModelImport(result)
        }
        .fileImporter(
            isPresented: Binding(
                get: { labelTargetID != nil },
                set: { if !$0 { labelTargetID = nil } }
            ),
            allowedContentTypes: [.plainText, .json, .yaml, .text, .data],
            allowsMultipleSelection: false
        ) { result in
            handleLabelImport(result)
        }
        .sheet(item: $inspecting) { model in
            ModelDetailView(model: model)
        }
    }

    private var supportedFormats: some View {
        CarbonTile {
            VStack(alignment: .leading, spacing: Space.s04) {
                CarbonSectionHeader(title: "What this app can read")
                VStack(alignment: .leading, spacing: Space.s03) {
                    FormatLine(
                        title: "Models",
                        detail: ".mlmodel and .mlpackage are compiled on import. "
                            + "Already-compiled .mlmodelc is used as is."
                    )
                    FormatLine(
                        title: "Detector heads",
                        detail: "Vision detectors, YOLO v5/v7 tensors with objectness, "
                            + "YOLO v8-v11 tensors, and NMS pipelines with confidence "
                            + "and coordinates outputs."
                    )
                    FormatLine(
                        title: "Labels",
                        detail: "One class per line in .txt or .names, a JSON array or "
                            + "index-to-name object, or the names block of an "
                            + "Ultralytics data.yaml."
                    )
                }
            }
        }
    }

    private func handleModelImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            if case .failure(let error) = result { importError = error.localizedDescription }
            return
        }
        Task {
            do {
                let model = try await store.importModel(from: url)
                importError = nil
                inspecting = model
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func handleLabelImport(_ result: Result<[URL], Error>) {
        guard let target = labelTargetID else { return }
        labelTargetID = nil
        guard case .success(let urls) = result, let url = urls.first else {
            if case .failure(let error) = result { importError = error.localizedDescription }
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let labels = try LabelSet.parse(data: data, sourceName: url.lastPathComponent)
            try store.attachLabels(labels, to: target)
            importError = nil
        } catch {
            importError = error.localizedDescription
        }
    }
}

private struct FormatLine: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s01) {
            Text(title)
                .font(CarbonType.headingCompact01())
                .foregroundStyle(Carbon.textPrimary)
            Text(detail)
                .font(CarbonType.helperText01())
                .foregroundStyle(Carbon.textHelper)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ModelRow: View {
    let model: StoredModel
    let isSelected: Bool
    let onSelect: () -> Void
    let onInspect: () -> Void
    let onAddLabels: () -> Void
    let onDelete: () -> Void

    @State private var confirmingDelete = false

    var body: some View {
        CarbonSelectableTile(isSelected: isSelected, action: onSelect) {
            VStack(alignment: .leading, spacing: Space.s04) {
                HStack(alignment: .top, spacing: Space.s04) {
                    VStack(alignment: .leading, spacing: Space.s02) {
                        Text(model.displayName)
                            .font(CarbonType.heading02())
                            .foregroundStyle(Carbon.textPrimary)
                            .lineLimit(2)
                        Text(model.originalFilename)
                            .font(CarbonType.code01())
                            .foregroundStyle(Carbon.textHelper)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Space.s03)
                    if isSelected {
                        CarbonTag(text: "ACTIVE", kind: .green, systemImage: "checkmark")
                    }
                }

                HStack(spacing: Space.s03) {
                    CarbonTag(text: model.summary.task.title, kind: .blue)
                    CarbonTag(text: model.summary.inputSizeText, kind: .outline)
                    CarbonTag(
                        text: "\(model.labels.count) classes",
                        kind: model.labels.origin == .placeholder ? .warning : .outline
                    )
                }

                if model.labels.origin == .placeholder {
                    Text("This model carries no class names. Add a label file so boxes are named.")
                        .font(CarbonType.helperText01())
                        .foregroundStyle(Carbon.supportWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: Space.s03) {
                    CarbonButton(
                        title: "Details", systemImage: "info.circle",
                        kind: .tertiary, size: .small, fullWidth: false, action: onInspect
                    )
                    CarbonButton(
                        title: "Labels", systemImage: "tag",
                        kind: .tertiary, size: .small, fullWidth: false, action: onAddLabels
                    )
                    Spacer(minLength: Space.s02)
                    CarbonIconButton(
                        systemImage: "trash",
                        accessibilityLabel: "Delete \(model.displayName)",
                        size: 32,
                        action: { confirmingDelete = true }
                    )
                }
            }
        }
        .confirmationDialog(
            "Delete \(model.displayName)?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete model", role: .destructive, action: onDelete)
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The compiled model and its labels are removed from this device.")
        }
    }
}
