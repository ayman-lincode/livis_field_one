import SwiftUI

/// What the app found inside an imported model, and the class list it will use.
struct ModelDetailView: View {
    let model: StoredModel

    @Environment(ModelStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var labelFilter = ""

    init(model: StoredModel) {
        self.model = model
        _name = State(initialValue: model.displayName)
    }

    private var filteredLabels: [(offset: Int, element: String)] {
        let all = Array(model.labels.names.enumerated())
        guard !labelFilter.isEmpty else { return all.map { (offset: $0.offset, element: $0.element) } }
        return all
            .filter { $0.element.localizedCaseInsensitiveContains(labelFilter) }
            .map { (offset: $0.offset, element: $0.element) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s05) {
                    nameField
                    identity
                    outputs
                    labels
                }
                .padding(Space.s05)
            }
            .background(Carbon.background)
            .navigationTitle("Model details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        try? store.rename(model.id, to: name)
                        dismiss()
                    }
                    .foregroundStyle(Carbon.textPrimary)
                }
            }
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: Space.s03) {
            CarbonSectionHeader(title: "Name")
            TextField("Model name", text: $name)
                .font(CarbonType.body01())
                .foregroundStyle(Carbon.textPrimary)
                .padding(.horizontal, Space.s05)
                .frame(height: 48)
                .background(Carbon.field01)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Carbon.borderStrong01).frame(height: 1)
                }
        }
    }

    private var identity: some View {
        CarbonTile {
            VStack(alignment: .leading, spacing: 0) {
                CarbonSectionHeader(title: "Identity")
                    .padding(.bottom, Space.s03)
                CarbonDataRow(key: "File", value: model.originalFilename)
                CarbonDataRow(key: "Task", value: model.summary.task.title, monospaced: false)
                CarbonDataRow(key: "Input", value: model.summary.inputSizeText)
                CarbonDataRow(key: "Input feature", value: model.summary.inputName ?? "unknown")
                CarbonDataRow(key: "Size on disk", value: byteText(model.byteSize))
                CarbonDataRow(key: "Imported", value: model.importedAt.formatted(date: .abbreviated, time: .shortened))
                if let author = model.summary.author, !author.isEmpty {
                    CarbonDataRow(key: "Author", value: author, monospaced: false)
                }
                if let version = model.summary.version, !version.isEmpty {
                    CarbonDataRow(key: "Version", value: version)
                }
                if let description = model.summary.modelDescription, !description.isEmpty {
                    VStack(alignment: .leading, spacing: Space.s02) {
                        Text("DESCRIPTION")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(Carbon.textHelper)
                        Text(description)
                            .font(CarbonType.helperText01())
                            .foregroundStyle(Carbon.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, Space.s04)
                }
            }
        }
    }

    private var outputs: some View {
        CarbonTile {
            VStack(alignment: .leading, spacing: 0) {
                CarbonSectionHeader(
                    title: "Outputs",
                    caption: "The shape the app decodes boxes from."
                )
                .padding(.bottom, Space.s03)
                ForEach(model.summary.outputs, id: \.name) { output in
                    CarbonDataRow(
                        key: output.name,
                        value: output.shape.isEmpty
                            ? output.kind
                            : "[\(output.shape.map(String.init).joined(separator: ", "))]"
                    )
                }
            }
        }
    }

    private var labels: some View {
        CarbonTile {
            VStack(alignment: .leading, spacing: Space.s04) {
                HStack {
                    CarbonSectionHeader(
                        title: "Classes",
                        caption: labelOriginCaption
                    )
                    Spacer()
                    CarbonTag(text: "\(model.labels.count)", kind: .outline)
                }

                if model.labels.count > 12 {
                    TextField("Filter classes", text: $labelFilter)
                        .font(CarbonType.bodyCompact01())
                        .foregroundStyle(Carbon.textPrimary)
                        .padding(.horizontal, Space.s04)
                        .frame(height: 40)
                        .background(Carbon.field02)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Carbon.borderStrong01).frame(height: 1)
                        }
                }

                if model.labels.names.isEmpty {
                    Text("No class names. Import a label file from the model list.")
                        .font(CarbonType.helperText01())
                        .foregroundStyle(Carbon.supportWarning)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 120), spacing: Space.s03)],
                        alignment: .leading,
                        spacing: Space.s03
                    ) {
                        ForEach(filteredLabels, id: \.offset) { item in
                            HStack(spacing: Space.s03) {
                                Rectangle()
                                    .fill(Carbon.categoricalColor(for: item.offset))
                                    .frame(width: 3, height: 16)
                                Text("\(item.offset)")
                                    .font(CarbonType.code01())
                                    .foregroundStyle(Carbon.textHelper)
                                Text(item.element)
                                    .font(CarbonType.bodyCompact01())
                                    .foregroundStyle(Carbon.textPrimary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }

    private var labelOriginCaption: String {
        switch model.labels.origin {
        case .model: "Read from the model's own metadata."
        case .file: "From \(model.labels.sourceName ?? "an imported file")."
        case .placeholder: "Generated. Import a label file to name them."
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
