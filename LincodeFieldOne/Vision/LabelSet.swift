import Foundation

/// The class names a model's output indices map onto.
struct LabelSet: Codable, Equatable {
    enum Origin: String, Codable {
        /// Read out of the model's own metadata.
        case model
        /// Imported from a file the operator chose.
        case file
        /// Generated because nothing else was available.
        case placeholder
    }

    var names: [String]
    var origin: Origin
    /// The filename the labels came from, when they came from a file.
    var sourceName: String?

    var count: Int { names.count }

    static let placeholderPrefix = "class_"

    func name(for index: Int) -> String {
        guard index >= 0, index < names.count else { return "\(Self.placeholderPrefix)\(index)" }
        return names[index]
    }

    static func placeholder(count: Int) -> LabelSet {
        LabelSet(
            names: (0..<max(0, count)).map { "\(placeholderPrefix)\($0)" },
            origin: .placeholder,
            sourceName: nil
        )
    }

    /// Parses the label formats a vision team actually hands over:
    /// newline-delimited `.txt`/`.names`, a JSON array, a JSON index-to-name
    /// object, or the `names:` block of an Ultralytics `data.yaml`.
    static func parse(data: Data, sourceName: String) throws -> LabelSet {
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            throw LabelImportError.unreadable
        }

        if let names = parseJSON(text), !names.isEmpty {
            return LabelSet(names: names, origin: .file, sourceName: sourceName)
        }
        if sourceName.lowercased().hasSuffix(".yaml") || sourceName.lowercased().hasSuffix(".yml"),
           let names = parseYAMLNames(text), !names.isEmpty {
            return LabelSet(names: names, origin: .file, sourceName: sourceName)
        }

        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !lines.isEmpty else { throw LabelImportError.empty }
        return LabelSet(names: lines, origin: .file, sourceName: sourceName)
    }

    /// Ultralytics writes `names` into CoreML metadata as a Python dict literal,
    /// e.g. `{0: 'person', 1: 'bicycle'}`. Older exports use a plain list.
    static func parseModelMetadata(_ raw: String) -> [String]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let names = parseJSON(trimmed), !names.isEmpty { return names }

        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
        var pairs: [(Int, String)] = []
        let body = trimmed.dropFirst().dropLast()
        let pattern = #"(\d+)\s*:\s*['"]([^'"]*)['"]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let string = String(body)
        let range = NSRange(string.startIndex..., in: string)
        regex.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let match,
                  let indexRange = Range(match.range(at: 1), in: string),
                  let nameRange = Range(match.range(at: 2), in: string),
                  let index = Int(string[indexRange]) else { return }
            pairs.append((index, String(string[nameRange])))
        }
        guard !pairs.isEmpty else { return nil }
        let highest = pairs.map(\.0).max() ?? 0
        var names = (0...highest).map { "\(placeholderPrefix)\($0)" }
        for (index, name) in pairs where index < names.count { names[index] = name }
        return names
    }

    private static func parseJSON(_ text: String) -> [String]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let array = object as? [String] { return array }
        if let dictionary = object as? [String: Any] {
            let pairs = dictionary.compactMap { key, value -> (Int, String)? in
                guard let index = Int(key) else { return nil }
                return (index, String(describing: value))
            }
            guard !pairs.isEmpty else { return nil }
            let highest = pairs.map(\.0).max() ?? 0
            var names = (0...highest).map { "\(placeholderPrefix)\($0)" }
            for (index, name) in pairs where index < names.count { names[index] = name }
            return names
        }
        return nil
    }

    private static func parseYAMLNames(_ text: String) -> [String]? {
        var collecting = false
        var indexed: [(Int, String)] = []
        var listed: [String] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("names:") {
                collecting = true
                let inline = trimmed.dropFirst("names:".count).trimmingCharacters(in: .whitespaces)
                if inline.hasPrefix("[") {
                    return inline
                        .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) }
                        .filter { !$0.isEmpty }
                }
                continue
            }
            guard collecting else { continue }
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") && !trimmed.isEmpty { break }

            if trimmed.hasPrefix("- ") {
                listed.append(
                    trimmed.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
                )
            } else if let colon = trimmed.firstIndex(of: ":"),
                      let index = Int(trimmed[trimmed.startIndex..<colon].trimmingCharacters(in: .whitespaces)) {
                let name = trimmed[trimmed.index(after: colon)...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
                indexed.append((index, name))
            }
        }

        if !indexed.isEmpty {
            let highest = indexed.map(\.0).max() ?? 0
            var names = (0...highest).map { "\(placeholderPrefix)\($0)" }
            for (index, name) in indexed where index < names.count { names[index] = name }
            return names
        }
        return listed.isEmpty ? nil : listed
    }
}

enum LabelImportError: LocalizedError {
    case unreadable
    case empty

    var errorDescription: String? {
        switch self {
        case .unreadable: "That label file is not readable text."
        case .empty: "That label file contains no class names."
        }
    }
}
