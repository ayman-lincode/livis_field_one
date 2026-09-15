import CoreGraphics
import CoreML
import Foundation

/// Checks the Models import for zips and folders, against built fixtures and,
/// when present, a real model zip passed in `MODEL_ZIP`.
@MainActor
enum ModelArchiveChecks {
    static func check(_ condition: Bool, _ description: String, _ detail: String = "") {
        Verify.check(condition, description, detail)
    }

    static func run() async {
        print("\n== Model zip import ==")
        check(ModelArchive.cleanDisplayName("best_coreml.mlpackage (1).zip") == "best_coreml",
              "zip and duplicate suffixes stripped from the name",
              ModelArchive.cleanDisplayName("best_coreml.mlpackage (1).zip"))

        guard let fixtures = ProcessInfo.processInfo.environment["ZIP_FIXTURES"] else {
            check(false, "ZIP_FIXTURES is set"); return
        }
        let root = URL(fileURLWithPath: fixtures)

        let iPhoneStaging = iPhoneLikeTemporaryDirectory
            .appendingPathComponent("private-prefix-\(UUID().uuidString)/unpacked", isDirectory: true)
        do {
            let count = try ModelArchive.extract(
                zipAt: root.appendingPathComponent("root-contents.mlpackage (1).zip"), to: iPhoneStaging
            )
            check(count > 0, "unpacks under /private/var, as the iPhone temporary folder is", "\(count) files")
        } catch {
            check(false, "unpacks under /private/var, as the iPhone temporary folder is", error.localizedDescription)
        }

        for (file, description) in [
            ("dot-prefix.zip", "entries written as ./Manifest.json"),
            ("root-contents.mlpackage (1).zip", "package contents at the zip root"),
            ("finder.zip", "Finder zip with an .mlpackage folder and __MACOSX"),
            ("stored.zip", "stored entries nested two folders deep"),
            ("zip64.zip", "Zip64 records"),
            ("descriptor.zip", "trailing data descriptors"),
            ("unzipped-folder.mlpackage (1)", "an unzipped folder with a Finder duplicate name")
        ] {
            await importAndRun(root.appendingPathComponent(file), description: description)
        }

        let prepared = try? prepare(root.appendingPathComponent("root-contents.mlpackage (1).zip"))
        check(prepared?.bundledLabels?.names == ["bright", "dark"], "label file zipped beside the model is picked up")

        // Extract into a known folder so the check can look beside it.
        let slipParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("slip-check-\(UUID().uuidString)", isDirectory: true)
        let slipTarget = slipParent.appendingPathComponent("unpacked", isDirectory: true)
        do {
            try ModelArchive.extract(zipAt: root.appendingPathComponent("slip.zip"), to: slipTarget)
            check(false, "zip-slip entry rejected", "extraction unexpectedly succeeded")
        } catch ModelArchiveError.unsafeEntry {
            check(true, "zip-slip entry rejected")
        } catch {
            check(false, "zip-slip entry rejected", "\(error)")
        }
        check(!FileManager.default.fileExists(atPath: slipParent.appendingPathComponent("escaped.txt").path),
              "nothing written outside the destination")
        expectFailure(root.appendingPathComponent("two-models.zip"), "two models in one zip refused") {
            if case ModelArchiveError.multipleModels = $0 { return true }; return false
        }
        expectFailure(root.appendingPathComponent("corrupt.zip"), "damaged zip data caught by the checksum") {
            if case ModelArchiveError.checksumMismatch = $0 { return true }
            if case ModelArchiveError.unreadable = $0 { return true }
            return false
        }

        if let real = ProcessInfo.processInfo.environment["MODEL_ZIP"],
           FileManager.default.fileExists(atPath: real) {
            print("\n== Your model zip: \(URL(fileURLWithPath: real).lastPathComponent) ==")
            await importAndRun(URL(fileURLWithPath: real), description: "the real model zip", verbose: true)
        }
    }

    /// iOS gives the app a temporary folder under `/private/var`. Standardising
    /// a path there drops "/private" for folders that exist but keeps it for
    /// files that do not yet, so every import here is staged under the same
    /// prefix to behave like an iPhone rather than a Mac.
    static var iPhoneLikeTemporaryDirectory: URL {
        let path = FileManager.default.temporaryDirectory.path
        return URL(fileURLWithPath: path.hasPrefix("/private") ? path : "/private" + path, isDirectory: true)
    }

    private static func prepare(_ source: URL) throws -> PreparedModel {
        let staging = iPhoneLikeTemporaryDirectory
            .appendingPathComponent("archive-check-\(UUID().uuidString)", isDirectory: true)
        return try ModelArchive.prepareImport(from: source, in: staging)
    }

    private static func expectFailure(_ source: URL, _ description: String, matches: (Error) -> Bool) {
        do {
            _ = try prepare(source)
            check(false, description, "import unexpectedly succeeded")
        } catch {
            check(matches(error), description, "\(error)")
        }
    }

    /// Runs the same sequence as `ModelStore.importModel`, then the detector.
    private static func importAndRun(_ source: URL, description: String, verbose: Bool = false) async {
        let started = Date()
        let prepared: PreparedModel
        do {
            prepared = try prepare(source)
        } catch {
            check(false, "unpacks: \(description)", error.localizedDescription); return
        }
        check(prepared.modelURL.pathExtension == prepared.format.rawValue,
              "unpacks: \(description) -> \(prepared.modelURL.lastPathComponent)")

        let compiledURL: URL
        do {
            compiledURL = prepared.format.needsCompiling
                ? try await MLModel.compileModel(at: prepared.modelURL)
                : prepared.modelURL
        } catch {
            check(false, "compiles: \(description)", error.localizedDescription); return
        }
        guard let model = try? MLModel(contentsOf: compiledURL) else {
            check(false, "loads: \(description)"); return
        }
        let summary = ModelStore.summarise(model)
        let modelLabels = ModelStore.labels(from: model, expectedCount: ModelStore.classCount(from: summary))
        let labels = modelLabels.origin == .placeholder ? (prepared.bundledLabels ?? modelLabels) : modelLabels
        check(summary.task != .unsupported, "reads as a detector: \(description)", "\(summary.task)")

        let stored = StoredModel(
            id: UUID(), displayName: prepared.displayName, originalFilename: source.lastPathComponent,
            importedAt: Date(), byteSize: 0, labels: labels, summary: summary
        )
        var settings = DetectionSettings()
        settings.confidenceThreshold = 0.25
        guard let detector = try? Detector(stored: stored, compiledURL: compiledURL, settings: settings),
              let image = CapturePathChecks.makeScene(width: 4216, height: 2376) else {
            check(false, "builds a detector: \(description)"); return
        }
        let frame = VideoFrame(
            image: .cgImage(image), size: CGSize(width: 4216, height: 2376), orientation: .up, capturedAt: 0
        )
        do {
            let result = try await detector.detect(frame, settings: settings)
            let layout = await detector.layoutDescription ?? "Vision decoded it"
            check(true, "runs on a camera-sized still: \(description) (\(layout))")
            if verbose {
                let seconds = Date().timeIntervalSince(started)
                print("        name        \(prepared.displayName)")
                print("        input       \(summary.inputName ?? "?") \(summary.inputSizeText)")
                for output in summary.outputs {
                    print("        output      \(output.name) \(output.shape)")
                }
                print("        classes     \(labels.count) from \(labels.origin.rawValue): \(labels.names.prefix(8).joined(separator: ", "))\(labels.count > 8 ? ", ..." : "")")
                print("        decoded as  \(layout)")
                print("        test still  \(result.detections.count) boxes above 0.25 in \(Int(result.inferenceMilliseconds)) ms")
                print("        unzip+compile+run \(String(format: "%.1f", seconds)) s")
            }
        } catch {
            check(false, "runs: \(description)", error.localizedDescription)
        }
    }
}
