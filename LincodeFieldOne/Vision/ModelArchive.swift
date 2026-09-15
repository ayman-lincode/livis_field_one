import Compression
import Foundation

/// What `ModelArchive.prepareImport` found and staged.
struct PreparedModel {
    enum Format: String {
        case mlmodel, mlpackage, mlmodelc

        /// Whether Core ML must compile this before it can be loaded.
        var needsCompiling: Bool { self != .mlmodelc }
    }

    /// A staged copy with the extension Core ML expects.
    let modelURL: URL
    let format: Format
    /// A clean name for the model list, without zip or duplicate suffixes.
    let displayName: String
    /// A label file that travelled with the model, if there was one.
    let bundledLabels: LabelSet?
    /// Number of files unpacked, when the source was a zip.
    let archiveFileCount: Int?
}

enum ModelArchiveError: LocalizedError {
    case unreadable(String)
    case encrypted(String)
    case unsupportedCompression(method: UInt16, entry: String)
    case unsafeEntry(String)
    case checksumMismatch(String)
    case tooLarge(needed: Int64, available: Int64)
    case noModel(found: [String])
    case multipleModels([String])

    var errorDescription: String? {
        switch self {
        case .unreadable(let detail):
            "That zip could not be read. \(detail)"
        case .encrypted(let entry):
            "\(entry) is password-protected. Export the zip without a password."
        case .unsupportedCompression(let method, let entry):
            "\(entry) uses zip compression method \(method), which this app cannot unpack. Re-zip it with standard compression."
        case .unsafeEntry(let entry):
            "The zip contains an unsafe path, \(entry), and was not unpacked."
        case .checksumMismatch(let entry):
            "\(entry) is damaged inside the zip. Download it again."
        case .tooLarge(let needed, let available):
            "Unpacking needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) but only "
                + "\(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) is free."
        case .noModel(let found):
            found.isEmpty
                ? "The zip is empty."
                : "No Core ML model was found in the zip. It contains: \(found.prefix(6).joined(separator: ", "))."
        case .multipleModels(let names):
            "The zip holds more than one model (\(names.joined(separator: ", "))). Zip one model at a time."
        }
    }
}

/// Turns whatever the operator picked into a single Core ML model Core ML can open.
///
/// Accepts a `.mlmodel`, `.mlpackage` or `.mlmodelc`, a folder holding one, or
/// a `.zip` of any of those. Zips exported from Python or Colab often store a
/// package's *contents* at the root, with no enclosing `.mlpackage` folder, and
/// Finder then unpacks them into a folder named like `best.mlpackage (1)`.
/// Those are recognised by their `Manifest.json` and `Data/com.apple.CoreML`
/// layout and given back the `.mlpackage` extension Core ML requires.
enum ModelArchive {

    // MARK: - Import

    /// Stages `source` inside `staging` and returns the model to compile. Does
    /// blocking file work; call it off the main actor.
    static func prepareImport(from source: URL, in staging: URL) throws -> PreparedModel {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let displayName = cleanDisplayName(source.lastPathComponent)
        let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

        if !isDirectory && isZip(source) {
            let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
            let count = try extract(zipAt: source, to: unpacked)
            // Read labels before locating the model: bare package contents at
            // the zip root are moved into a new .mlpackage, taking the folder.
            let labels = bundledLabels(in: unpacked)
            let (modelURL, format) = try locateModel(in: unpacked, stagingRoot: staging, name: displayName)
            return PreparedModel(
                modelURL: modelURL,
                format: format,
                displayName: displayName,
                bundledLabels: labels,
                archiveFileCount: count
            )
        }

        if !isDirectory {
            guard source.pathExtension.lowercased() == "mlmodel" else {
                throw ModelError.unsupportedFile(source.lastPathComponent)
            }
            let staged = staging.appendingPathComponent("\(displayName).mlmodel")
            try fileManager.copyItem(at: source, to: staged)
            return PreparedModel(
                modelURL: staged, format: .mlmodel, displayName: displayName,
                bundledLabels: nil, archiveFileCount: nil
            )
        }

        // A folder: a package or compiled model by name, package contents under
        // any name, or a folder that holds exactly one model.
        let copied = staging.appendingPathComponent("picked", isDirectory: true)
        try fileManager.copyItem(at: source, to: copied)
        let ext = source.pathExtension.lowercased()
        if let format = PreparedModel.Format(rawValue: ext), format != .mlmodel {
            let staged = staging.appendingPathComponent("\(displayName).\(ext)")
            try fileManager.moveItem(at: copied, to: staged)
            return PreparedModel(
                modelURL: staged, format: format, displayName: displayName,
                bundledLabels: nil, archiveFileCount: nil
            )
        }
        let labels = bundledLabels(in: copied)
        let (modelURL, format) = try locateModel(in: copied, stagingRoot: staging, name: displayName)
        return PreparedModel(
            modelURL: modelURL, format: format, displayName: displayName,
            bundledLabels: labels, archiveFileCount: nil
        )
    }

    /// `best_coreml.mlpackage (1).zip` becomes `best_coreml`.
    static func cleanDisplayName(_ filename: String) -> String {
        var name = filename
        let suffixes = [".zip", ".mlpackage", ".mlmodelc", ".mlmodel"]
        var changed = true
        while changed {
            changed = false
            if let range = name.range(of: #"\s*\(\d+\)$"#, options: .regularExpression) {
                name.removeSubrange(range)
                changed = true
            }
            for suffix in suffixes where name.lowercased().hasSuffix(suffix) {
                name.removeLast(suffix.count)
                changed = true
            }
        }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Imported model" : name
    }

    static func isZip(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "zip" { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let magic = (try? handle.read(upToCount: 4)) ?? Data()
        return magic == Data([0x50, 0x4B, 0x03, 0x04])
    }

    // MARK: - Locating the model

    /// Directory contents that are an `.mlpackage` in all but name.
    static func looksLikePackageContents(_ directory: URL) -> Bool {
        let fileManager = FileManager.default
        let manifest = directory.appendingPathComponent("Manifest.json")
        let coreML = directory.appendingPathComponent("Data/com.apple.CoreML", isDirectory: true)
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: manifest.path)
            && fileManager.fileExists(atPath: coreML.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Finds the single model under `root` and returns it with a Core ML
    /// extension, renaming bare package contents to `<name>.mlpackage`.
    static func locateModel(
        in root: URL,
        stagingRoot: URL,
        name: String
    ) throws -> (URL, PreparedModel.Format) {
        var candidates: [(url: URL, format: PreparedModel.Format, bare: Bool)] = []
        var seenFiles: [String] = []

        func visit(_ directory: URL, depth: Int) {
            if looksLikePackageContents(directory) {
                candidates.append((directory, .mlpackage, directory.pathExtension.lowercased() != "mlpackage"))
                return
            }
            guard depth < 6, let children = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let childName = child.lastPathComponent
                if childName == "__MACOSX" { continue }
                let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let ext = child.pathExtension.lowercased()
                if isDirectory {
                    switch ext {
                    case "mlpackage": candidates.append((child, .mlpackage, false))
                    case "mlmodelc": candidates.append((child, .mlmodelc, false))
                    default: visit(child, depth: depth + 1)
                    }
                } else {
                    seenFiles.append(childName)
                    if ext == "mlmodel" { candidates.append((child, .mlmodel, false)) }
                }
            }
        }
        visit(root, depth: 0)

        guard !candidates.isEmpty else { throw ModelArchiveError.noModel(found: seenFiles) }
        guard candidates.count == 1, let found = candidates.first else {
            throw ModelArchiveError.multipleModels(candidates.map(\.url.lastPathComponent))
        }

        let destination = stagingRoot.appendingPathComponent("\(name).\(found.format.rawValue)")
        if found.url.standardizedFileURL == destination.standardizedFileURL {
            return (destination, found.format)
        }
        try FileManager.default.moveItem(at: found.url, to: destination)
        return (destination, found.format)
    }

    /// A class-name file shipped beside the model, in priority order.
    static func bundledLabels(in root: URL) -> LabelSet? {
        let preferred = ["labels.txt", "classes.txt", "data.yaml", "labels.json", "classes.json"]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        var found: [URL] = []
        for case let url as URL in enumerator {
            let path = url.path
            if path.contains("/__MACOSX") || path.contains(".mlpackage/") || path.contains(".mlmodelc/")
                || path.contains("/Data/com.apple.CoreML") { continue }
            let name = url.lastPathComponent.lowercased()
            if preferred.contains(name) || name.hasSuffix(".names") || name.hasSuffix(".yaml") {
                found.append(url)
            }
        }

        let ranked = found.sorted { lhs, rhs in
            let l = preferred.firstIndex(of: lhs.lastPathComponent.lowercased()) ?? preferred.count
            let r = preferred.firstIndex(of: rhs.lastPathComponent.lowercased()) ?? preferred.count
            return l < r
        }
        for url in ranked {
            guard let data = try? Data(contentsOf: url),
                  let labels = try? LabelSet.parse(data: data, sourceName: url.lastPathComponent),
                  !labels.names.isEmpty else { continue }
            return labels
        }
        return nil
    }

    // MARK: - Zip extraction

    private struct Entry {
        let name: String
        let method: UInt16
        let flags: UInt16
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
        let isDirectory: Bool
        let isSymlink: Bool
    }

    /// Unpacks a zip to `destination`, streaming each file so large weight
    /// files never sit in memory. Handles stored and deflated entries, Zip64
    /// and data descriptors; rejects encryption and paths that escape the
    /// destination. Returns the number of files written.
    @discardableResult
    static func extract(zipAt archive: URL, to destination: URL) throws -> Int {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: archive)
        } catch {
            throw ModelArchiveError.unreadable(error.localizedDescription)
        }
        defer { try? handle.close() }

        let entries = try readCentralDirectory(handle)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let needed = entries.reduce(Int64(0)) { $0 + Int64(clamping: $1.uncompressedSize) }
        if let available = try? destination.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage, available > 0, needed > available {
            throw ModelArchiveError.tooLarge(needed: needed, available: available)
        }

        var written = 0
        for entry in entries {
            let components = try safeComponents(of: entry.name)
            if components.first == "__MACOSX" || components.last?.hasPrefix("._") == true
                || components.last == ".DS_Store" || entry.isSymlink {
                continue
            }
            let target = try safeURL(components: components, name: entry.name, under: destination)

            if entry.isDirectory {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            if entry.flags & 0x1 != 0 { throw ModelArchiveError.encrypted(entry.name) }

            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try write(entry, from: handle, to: target)
            written += 1
        }
        return written
    }

    /// Splits an entry name into path components, refusing any that could
    /// place a file outside the unpack folder. `.` components are dropped so
    /// `./Manifest.json` unpacks like `Manifest.json`.
    private static func safeComponents(of name: String) throws -> [String] {
        let normalised = name.replacingOccurrences(of: "\\", with: "/")
        let components = normalised
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." }
        let isDriveLetter = components.first.map { $0.count == 2 && $0.hasSuffix(":") } ?? false
        guard !normalised.hasPrefix("/"), !components.isEmpty, !isDriveLetter,
              !components.contains("..") else {
            throw ModelArchiveError.unsafeEntry(name)
        }
        return components
    }

    /// Containment is decided on the path as written, never on a standardised
    /// one. On iOS the temporary folder is under `/private/var`, and
    /// standardising drops "/private" for folders that exist but keeps it for
    /// files not yet written, which made every entry look like it escaped.
    /// `..` and absolute names are refused above and symlink entries are
    /// never written, so a lexical check is sufficient.
    private static func safeURL(components: [String], name: String, under destination: URL) throws -> URL {
        let url = components.reduce(destination) { $0.appendingPathComponent($1) }
        guard url.path.hasPrefix(destination.path + "/") else {
            throw ModelArchiveError.unsafeEntry(name)
        }
        return url
    }

    private static func readCentralDirectory(_ handle: FileHandle) throws -> [Entry] {
        let fileSize = try handle.seekToEnd()
        guard fileSize >= 22 else { throw ModelArchiveError.unreadable("The file is too short to be a zip.") }

        // End of central directory: fixed 22 bytes plus a comment of up to 65535.
        let tailLength = min(fileSize, 22 + 65_535)
        try handle.seek(toOffset: fileSize - tailLength)
        let tail = try handle.read(upToCount: Int(tailLength)) ?? Data()
        guard let eocd = lastSignature(0x0605_4B50, in: tail) else {
            throw ModelArchiveError.unreadable("Its end-of-archive record is missing.")
        }

        var entryCount = UInt64(tail.le16(eocd + 10))
        var directorySize = UInt64(tail.le32(eocd + 12))
        var directoryOffset = UInt64(tail.le32(eocd + 16))

        if entryCount == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            // Zip64: a locator sits immediately before the classic record.
            guard eocd >= 20, tail.le32(eocd - 20) == 0x0706_4B50 else {
                throw ModelArchiveError.unreadable("Its Zip64 locator is missing.")
            }
            let recordOffset = tail.le64(eocd - 20 + 8)
            try handle.seek(toOffset: recordOffset)
            let record = try handle.read(upToCount: 56) ?? Data()
            guard record.count == 56, record.le32(0) == 0x0606_4B50 else {
                throw ModelArchiveError.unreadable("Its Zip64 record is damaged.")
            }
            entryCount = record.le64(32)
            directorySize = record.le64(40)
            directoryOffset = record.le64(48)
        }

        guard directoryOffset + directorySize <= fileSize, directorySize < 512 * 1024 * 1024 else {
            throw ModelArchiveError.unreadable("Its file list points outside the archive.")
        }
        try handle.seek(toOffset: directoryOffset)
        let directory = try handle.read(upToCount: Int(directorySize)) ?? Data()

        var entries: [Entry] = []
        var cursor = 0
        for _ in 0..<entryCount {
            guard cursor + 46 <= directory.count, directory.le32(cursor) == 0x0201_4B50 else {
                throw ModelArchiveError.unreadable("Its file list is damaged.")
            }
            let versionMadeBy = directory.le16(cursor + 4)
            let flags = directory.le16(cursor + 8)
            let method = directory.le16(cursor + 10)
            let crc = directory.le32(cursor + 16)
            var compressed = UInt64(directory.le32(cursor + 20))
            var uncompressed = UInt64(directory.le32(cursor + 24))
            let nameLength = Int(directory.le16(cursor + 28))
            let extraLength = Int(directory.le16(cursor + 30))
            let commentLength = Int(directory.le16(cursor + 32))
            let externalAttributes = directory.le32(cursor + 38)
            var localOffset = UInt64(directory.le32(cursor + 42))

            let nameStart = cursor + 46
            guard nameStart + nameLength + extraLength + commentLength <= directory.count else {
                throw ModelArchiveError.unreadable("Its file list is truncated.")
            }
            let nameData = directory.subdata(in: nameStart..<(nameStart + nameLength))
            let name = (flags & 0x800 != 0 ? String(data: nameData, encoding: .utf8) : nil)
                ?? String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
                ?? ""

            // Zip64 extended information replaces any field saturated at 0xFFFFFFFF.
            var extraCursor = nameStart + nameLength
            let extraEnd = extraCursor + extraLength
            while extraCursor + 4 <= extraEnd {
                let id = directory.le16(extraCursor)
                let size = Int(directory.le16(extraCursor + 2))
                var field = extraCursor + 4
                if id == 0x0001 {
                    if uncompressed == 0xFFFF_FFFF, field + 8 <= extraEnd {
                        uncompressed = directory.le64(field); field += 8
                    }
                    if compressed == 0xFFFF_FFFF, field + 8 <= extraEnd {
                        compressed = directory.le64(field); field += 8
                    }
                    if localOffset == 0xFFFF_FFFF, field + 8 <= extraEnd {
                        localOffset = directory.le64(field)
                    }
                }
                extraCursor += 4 + size
            }

            let unixMode = (versionMadeBy >> 8) == 3 ? (externalAttributes >> 16) & 0o170000 : 0
            entries.append(Entry(
                name: name,
                method: method,
                flags: flags,
                crc32: crc,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                localHeaderOffset: localOffset,
                isDirectory: name.hasSuffix("/"),
                isSymlink: unixMode == 0o120000
            ))
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static let chunkSize = 1 << 20

    private static func write(_ entry: Entry, from handle: FileHandle, to target: URL) throws {
        // Sizes come from the central directory, which stays correct even when
        // the local header defers them to a trailing data descriptor.
        try handle.seek(toOffset: entry.localHeaderOffset)
        let header = try handle.read(upToCount: 30) ?? Data()
        guard header.count == 30, header.le32(0) == 0x0403_4B50 else {
            throw ModelArchiveError.unreadable("The entry \(entry.name) is damaged.")
        }
        let dataOffset = entry.localHeaderOffset + 30
            + UInt64(header.le16(26)) + UInt64(header.le16(28))
        try handle.seek(toOffset: dataOffset)

        guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
            throw ModelArchiveError.unreadable("Could not create \(target.lastPathComponent).")
        }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }

        var crc = CRC32()
        var produced: UInt64 = 0

        switch entry.method {
        case 0:
            var remaining = entry.compressedSize
            while remaining > 0 {
                let count = Int(min(UInt64(chunkSize), remaining))
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else {
                    throw ModelArchiveError.unreadable("\(entry.name) ends early.")
                }
                crc.update(chunk)
                try output.write(contentsOf: chunk)
                produced += UInt64(chunk.count)
                remaining -= UInt64(chunk.count)
            }

        case 8:
            produced = try inflate(entry, from: handle, into: output, crc: &crc)

        default:
            throw ModelArchiveError.unsupportedCompression(method: entry.method, entry: entry.name)
        }

        guard produced == entry.uncompressedSize else {
            throw ModelArchiveError.unreadable("\(entry.name) unpacked to the wrong size.")
        }
        guard crc.value == entry.crc32 else {
            throw ModelArchiveError.checksumMismatch(entry.name)
        }
    }

    /// Streams raw DEFLATE, which is what `COMPRESSION_ZLIB` decodes.
    private static func inflate(
        _ entry: Entry,
        from handle: FileHandle,
        into output: FileHandle,
        crc: inout CRC32
    ) throws -> UInt64 {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ModelArchiveError.unreadable("The decompressor could not start.")
        }
        defer { compression_stream_destroy(stream) }

        let source = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer {
            source.deallocate()
            destination.deallocate()
        }

        var remaining = entry.compressedSize
        var produced: UInt64 = 0
        stream.pointee.src_size = 0
        stream.pointee.src_ptr = UnsafePointer(source)

        while true {
            if stream.pointee.src_size == 0, remaining > 0 {
                let count = Int(min(UInt64(chunkSize), remaining))
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else {
                    throw ModelArchiveError.unreadable("\(entry.name) ends early.")
                }
                chunk.copyBytes(to: source, count: chunk.count)
                stream.pointee.src_ptr = UnsafePointer(source)
                stream.pointee.src_size = chunk.count
                remaining -= UInt64(chunk.count)
            }

            stream.pointee.dst_ptr = destination
            stream.pointee.dst_size = chunkSize
            let flags = remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status = compression_stream_process(stream, flags)
            let count = chunkSize - stream.pointee.dst_size

            if count > 0 {
                let data = Data(bytes: destination, count: count)
                crc.update(data)
                try output.write(contentsOf: data)
                produced += UInt64(count)
                if produced > entry.uncompressedSize {
                    throw ModelArchiveError.unreadable("\(entry.name) unpacks larger than the zip says.")
                }
            }

            switch status {
            case COMPRESSION_STATUS_END:
                return produced
            case COMPRESSION_STATUS_OK:
                if count == 0, stream.pointee.src_size == 0, remaining == 0 {
                    throw ModelArchiveError.unreadable("\(entry.name) is truncated.")
                }
            default:
                throw ModelArchiveError.unreadable("\(entry.name) could not be decompressed.")
            }
        }
    }

    private static func lastSignature(_ signature: UInt32, in data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        var index = data.count - 4
        while index >= 0 {
            if data.le32(index) == signature { return index }
            index -= 1
        }
        return nil
    }
}

/// Standard CRC-32 (IEEE), as used by zip.
struct CRC32 {
    private(set) var value: UInt32 = 0

    private static let table: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index)
        for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        return crc
    }

    mutating func update(_ data: Data) {
        var crc = ~value
        data.withUnsafeBytes { buffer in
            for byte in buffer.bindMemory(to: UInt8.self) {
                crc = Self.table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        value = ~crc
    }
}

private extension Data {
    func le16(_ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
    }

    func le32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    func le64(_ offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= count else { return 0 }
        return withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
    }
}
