import CoreML
import Foundation
import UniformTypeIdentifiers

enum ModelError: LocalizedError {
    case unsupportedFile(String)
    case compileFailed(String)
    case loadFailed(String)
    case notADetector(String)
    case unsupportedOutput(String)
    case noModelSelected

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let name):
            "\(name) is not a Core ML model. Import a .mlmodel, .mlpackage or .mlmodelc."
        case .compileFailed(let detail):
            "Core ML could not compile that model. \(detail)"
        case .loadFailed(let detail):
            "Core ML could not load that model. \(detail)"
        case .notADetector(let detail):
            detail
        case .unsupportedOutput(let detail):
            detail
        case .noModelSelected:
            "Choose a model before starting inference."
        }
    }
}

/// How the app will read a model's output.
enum ModelTask: String, Codable {
    /// Vision returns `VNRecognizedObjectObservation` directly.
    case visionDetector
    /// A raw tensor the app decodes itself.
    case rawTensor
    /// A two-output NMS pipeline: confidence plus coordinates.
    case nmsPipeline
    /// Not an object detector.
    case unsupported

    var title: String {
        switch self {
        case .visionDetector: "Vision detector"
        case .rawTensor: "Raw tensor"
        case .nmsPipeline: "NMS pipeline"
        case .unsupported: "Unsupported"
        }
    }
}

/// What the app learned about a model when it was imported.
struct ModelSummary: Codable, Equatable {
    var task: ModelTask
    var inputName: String?
    var inputWidth: Int?
    var inputHeight: Int?
    var outputs: [OutputDescription]
    var author: String?
    var modelDescription: String?
    var license: String?
    var version: String?

    struct OutputDescription: Codable, Equatable {
        var name: String
        var shape: [Int]
        var kind: String
    }

    var inputSize: CGSize {
        CGSize(width: inputWidth ?? 640, height: inputHeight ?? 640)
    }

    var inputSizeText: String {
        guard let inputWidth, let inputHeight else { return "unknown" }
        return "\(inputWidth) x \(inputHeight)"
    }
}

/// A model the operator imported, as persisted on disk.
struct StoredModel: Identifiable, Codable, Equatable {
    let id: UUID
    var displayName: String
    var originalFilename: String
    var importedAt: Date
    var byteSize: Int64
    var labels: LabelSet
    var summary: ModelSummary

    var isUsable: Bool { summary.task != .unsupported }
}

/// Imports, compiles and keeps track of the operator's Core ML models.
@MainActor
@Observable
final class ModelStore {
    private(set) var models: [StoredModel] = []
    private(set) var selectedModelID: UUID?
    private(set) var isImporting = false
    var lastError: String?

    var selectedModel: StoredModel? {
        guard let selectedModelID else { return nil }
        return models.first { $0.id == selectedModelID }
    }

    private let root: URL
    private let defaults = UserDefaults.standard
    private let selectionKey = "selectedModelID"

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
        if let raw = defaults.string(forKey: selectionKey), let id = UUID(uuidString: raw),
           models.contains(where: { $0.id == id }) {
            selectedModelID = id
        } else {
            selectedModelID = models.first(where: \.isUsable)?.id
        }
    }

    // MARK: - Paths

    func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func compiledModelURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("Model.mlmodelc", isDirectory: true)
    }

    private func manifestURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("manifest.json")
    }

    // MARK: - Loading

    func reload() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        )) ?? []

        models = contents.compactMap { folder -> StoredModel? in
            let manifest = folder.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifest) else { return nil }
            return try? decoder.decode(StoredModel.self, from: data)
        }
        .sorted { $0.importedAt > $1.importedAt }
    }

    func select(_ id: UUID?) {
        selectedModelID = id
        defaults.set(id?.uuidString, forKey: selectionKey)
    }

    // MARK: - Import

    /// Compiles and stores a `.mlmodel`, `.mlpackage` or `.mlmodelc` chosen by
    /// the operator. Security-scoped access is handled here because the picker
    /// hands back a URL outside the app container.
    func importModel(from source: URL) async throws -> StoredModel {
        isImporting = true
        defer { isImporting = false }

        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let filename = source.lastPathComponent
        let ext = source.pathExtension.lowercased()
        guard ["mlmodel", "mlpackage", "mlmodelc"].contains(ext) else {
            throw ModelError.unsupportedFile(filename)
        }

        // Stage into the container first: compilation cannot read an
        // iCloud/Files URL reliably once the scope is released.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: source, to: staged)

        let compiled: URL
        if ext == "mlmodelc" {
            compiled = staged
        } else {
            compiled = try await Self.compile(staged)
        }

        let model = try MLModel(contentsOf: compiled)
        let summary = Self.summarise(model)
        guard summary.task != .unsupported else {
            throw ModelError.notADetector(
                "\(filename) does not look like an object detector. Its outputs are: "
                + summary.outputs.map(\.name).joined(separator: ", ") + "."
            )
        }

        let id = UUID()
        let folder = directory(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = compiledModelURL(for: id)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: compiled, to: destination)
        if ext != "mlmodelc" { try? FileManager.default.removeItem(at: compiled) }

        let labels = Self.labels(from: model, expectedCount: Self.classCount(from: summary))
        let stored = StoredModel(
            id: id,
            displayName: source.deletingPathExtension().lastPathComponent,
            originalFilename: filename,
            importedAt: Date(),
            byteSize: Self.size(of: destination),
            labels: labels,
            summary: summary
        )
        try write(stored)
        reload()
        if selectedModelID == nil { select(stored.id) }
        return stored
    }

    /// Replaces the labels on a model with ones the operator imported.
    func attachLabels(_ labels: LabelSet, to id: UUID) throws {
        guard var model = models.first(where: { $0.id == id }) else { return }
        model.labels = labels
        try write(model)
        reload()
    }

    func rename(_ id: UUID, to name: String) throws {
        guard var model = models.first(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.displayName = trimmed
        try write(model)
        reload()
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory(for: id))
        if selectedModelID == id { select(nil) }
        reload()
        if selectedModelID == nil { select(models.first(where: \.isUsable)?.id) }
    }

    private func write(_ model: StoredModel) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: directory(for: model.id), withIntermediateDirectories: true
        )
        try encoder.encode(model).write(to: manifestURL(for: model.id), options: .atomic)
    }

    // MARK: - Inspection

    private static func compile(_ url: URL) async throws -> URL {
        do {
            if #available(iOS 18.0, *) {
                return try await MLModel.compileModel(at: url)
            } else {
                return try await Task.detached(priority: .userInitiated) {
                    try MLModel.compileModel(at: url)
                }.value
            }
        } catch {
            throw ModelError.compileFailed(error.localizedDescription)
        }
    }

    static func summarise(_ model: MLModel) -> ModelSummary {
        let description = model.modelDescription
        let metadata = description.metadata

        var inputName: String?
        var inputWidth: Int?
        var inputHeight: Int?
        for (name, feature) in description.inputDescriptionsByName {
            guard feature.type == .image, let constraint = feature.imageConstraint else { continue }
            inputName = name
            inputWidth = constraint.pixelsWide
            inputHeight = constraint.pixelsHigh
            break
        }

        var outputs: [ModelSummary.OutputDescription] = []
        for (name, feature) in description.outputDescriptionsByName.sorted(by: { $0.key < $1.key }) {
            let shape = feature.multiArrayConstraint?.shape.map(\.intValue) ?? []
            let kind: String
            switch feature.type {
            case .multiArray: kind = "multiArray"
            case .dictionary: kind = "dictionary"
            case .image: kind = "image"
            case .string: kind = "string"
            case .double: kind = "double"
            case .int64: kind = "int64"
            case .sequence: kind = "sequence"
            default: kind = "other"
            }
            outputs.append(.init(name: name, shape: shape, kind: kind))
        }

        let names = Set(outputs.map(\.name))
        let task: ModelTask
        if names.contains("confidence") && names.contains("coordinates") {
            // Vision reads this shape as a detector; the app can also decode it.
            task = .visionDetector
        } else if inputName != nil && outputs.contains(where: { $0.kind == "multiArray" }) {
            task = .rawTensor
        } else if inputName == nil {
            task = .unsupported
        } else {
            task = .unsupported
        }

        return ModelSummary(
            task: task,
            inputName: inputName,
            inputWidth: inputWidth,
            inputHeight: inputHeight,
            outputs: outputs,
            author: metadata[.author] as? String,
            modelDescription: metadata[.description] as? String,
            license: metadata[.license] as? String,
            version: metadata[.versionString] as? String
        )
    }

    /// How many classes the output tensor implies, so imported labels can be
    /// checked against the model instead of silently mismatching.
    static func classCount(from summary: ModelSummary) -> Int? {
        if let confidence = summary.outputs.first(where: { $0.name == "confidence" }),
           let last = confidence.shape.last, last > 0 {
            return last
        }
        guard let tensor = summary.outputs.first(where: { $0.kind == "multiArray" && $0.shape.count >= 2 })
        else { return nil }
        var dims = tensor.shape
        if dims.first == 1 { dims.removeFirst() }
        guard dims.count == 2 else { return nil }
        let channels = min(dims[0], dims[1])
        guard channels > 4 else { return nil }
        return channels == 85 ? 80 : channels - 4
    }

    static func labels(from model: MLModel, expectedCount: Int?) -> LabelSet {
        let description = model.modelDescription

        if let classLabels = description.classLabels as? [String], !classLabels.isEmpty {
            return LabelSet(names: classLabels, origin: .model, sourceName: nil)
        }

        // Ultralytics and several other exporters write class names into
        // user-defined metadata under "names" or "classes".
        let userMetadata = description.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        for key in ["names", "classes", "labels"] {
            guard let raw = userMetadata[key],
                  let parsed = LabelSet.parseModelMetadata(raw),
                  !parsed.isEmpty else { continue }
            return LabelSet(names: parsed, origin: .model, sourceName: nil)
        }

        return .placeholder(count: expectedCount ?? 0)
    }

    private static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys)
        ) else {
            return Int64((try? url.resourceValues(forKeys: keys).fileAllocatedSize) ?? 0)
        }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            let values = try? child.resourceValues(forKeys: keys)
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}

extension UTType {
    static let coreMLModel = UTType(filenameExtension: "mlmodel") ?? .data
    static let coreMLPackage = UTType(filenameExtension: "mlpackage") ?? .data
    static let coreMLCompiled = UTType(filenameExtension: "mlmodelc") ?? .data
}
