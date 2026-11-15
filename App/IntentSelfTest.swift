#if DEBUG
import AppIntents
import AppKit
import GlimmerAI
import GlimmerCore
import ImageIO

/// `-intentSelfTest YES` (debug builds): runs every Shortcuts action through its own perform()
/// with real parameters, on tmp/intent-selftest/input.jpg in the app's container, writes each
/// result and report.json next to it, and quits. Only the hand-over from the Shortcuts app is
/// left out; that needs Shortcuts itself.
enum IntentSelfTest {
    @MainActor static func runIfAsked() {
        guard UserDefaults.standard.bool(forKey: "intentSelfTest") else { return }
        Task { @MainActor in
            await run()
            NSApp.terminate(nil)
        }
    }

    @MainActor static func run() async {
        let dir = FileManager.default.temporaryDirectory.appending(path: "intent-selftest")
        let input = dir.appending(path: "input.jpg")
        var report: [[String: Any]] = []

        func check<R: IntentResult & ReturnsValue<IntentFile>>(_ name: String, _ perform: () async throws -> R) async {
            do {
                guard let file = try await perform().value else { throw HeadlessEditor.Failure(message: "no file returned") }
                let out = dir.appending(path: "out-\(name)-\(file.filename)")
                try file.data.write(to: out)
                let source = CGImageSourceCreateWithData(file.data as CFData, nil)
                let image = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                let type = source.flatMap { CGImageSourceGetType($0) as String? } ?? "?"
                report.append(["intent": name, "ok": image != nil, "file": file.filename, "type": type,
                               "bytes": file.data.count, "width": image?.width ?? 0, "height": image?.height ?? 0])
            } catch {
                report.append(["intent": name, "ok": false, "error": "\(error)"])
            }
        }

        let image = IntentFile(fileURL: input, filename: "input.jpg", type: .jpeg)

        var enhance = AutoEnhanceIntent()
        enhance.image = image; enhance.format = .jpeg
        await check("AutoEnhanceIntent") { try await enhance.perform() }

        var cutout = RemoveBackgroundIntent()
        cutout.image = image
        await check("RemoveBackgroundIntent") { try await cutout.perform() }

        if let preset = Preset.all.first {
            var apply = ApplyPresetIntent()
            apply.image = image; apply.preset = PresetEntity(preset); apply.format = .png
            await check("ApplyPresetIntent") { try await apply.perform() }
        }

        var filter = ApplyFilterIntent()
        filter.image = image; filter.filter = .gaussianBlur; filter.format = .heic
        await check("ApplyFilterIntent") { try await filter.perform() }

        var export = ExportImageIntent()
        export.document = image; export.format = .webp
        await check("ExportImageIntent") { try await export.perform() }

        // A saved action, stored like the assistant stores one, then put back as it was.
        let saved = SavedAction.load()
        let action = SavedAction(name: "Self-test invert", steps: [AgentStep(op: "add_adjustment", params: ["type": .string("invert")])])
        SavedAction.store(saved + [action])
        var run = RunActionIntent()
        run.image = image; run.action = SavedActionEntity(action); run.format = .tiff
        await check("RunActionIntent") { try await run.perform() }
        SavedAction.store(saved)

        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appending(path: "report.json"))
        }
    }
}
#endif
