import Foundation
@testable import GlimmerAI
import Testing

/// The register of what Glimmer may need installed (SIBLINGS.md "Det som kan behöva installeras"):
/// every entry is complete, every operation that can answer `model_missing` has entries, and
/// THIRD_PARTY_NOTICES.md is the register's own tables.
@Suite struct RequirementsTests {
    static let repo = SiteExportTests.repo
    /// Licenses that allow commercial use and aren't copyleft: what Glimmer may fetch or bundle.
    static let permissive: Set<String> = ["MIT", "Apache-2.0", "BSD-3-Clause", "BSD-2-Clause", "ISC", "Zlib"]

    @Test func everyEntryHasSourceVersionChecksumAndLicense() {
        for r in Requirement.all {
            #expect(!r.id.isEmpty && !r.name.isEmpty && !r.neededBy.isEmpty, "\(r.id): id, name and neededBy")
            #expect(r.source.url.hasPrefix("https://"), "\(r.id): source")
            #expect(!r.source.publisher.isEmpty && !r.source.version.isEmpty, "\(r.id): publisher and version")
            #expect(!r.source.checksumsFrom.isEmpty, "\(r.id): where the checksums were read")
            #expect(!r.license.spdx.isEmpty && r.license.url.hasPrefix("https://"), "\(r.id): license and its text")
            #expect(!r.location.isEmpty && !r.removal.isEmpty, "\(r.id): where it goes and how it is removed")
            #expect(r.source.sha256 != nil || r.source.sha256Note != nil, "\(r.id): a SHA-256, or why there is none")
            if let sha = r.source.sha256 { #expect(sha.count == 64 && sha.allSatisfy(\.isHexDigit), "\(r.id): SHA-256 form") }
            switch r.install {
            case .inApp:
                #expect(r.source.commit?.count == 40, "\(r.id): a pinned commit")
                #expect(!r.files.isEmpty, "\(r.id): its files")
                for f in r.files {
                    #expect(f.size > 0, "\(r.id) \(f.path): size")
                    #expect((f.sha256?.count == 64) || (f.gitBlob?.count == 40), "\(r.id) \(f.path): a SHA-256 or a git blob id")
                }
                #expect(r.files.reduce(0) { $0 + $1.size } == r.sizeBytes, "\(r.id): sizeBytes is the sum of its files")
                #expect(Self.permissive.contains(r.license.spdx), "\(r.id): what Glimmer fetches is never GPL or non-commercial")
            case .byUser(let steps, let v):
                #expect(!steps.isEmpty && !v.command.isEmpty && !v.minVersion.isEmpty && !v.minVersionFrom.isEmpty, "\(r.id): steps and verify")
                #expect(v.teamID != nil || v.note != nil, "\(r.id): a Team ID, or why it isn't read")
                for step in steps {
                    #expect(!step.contains("| sh") && !step.contains("|sh") && !step.contains("sudo"), "\(r.id): no piped installer, no sudo")
                    #expect(!step.contains("xattr") && !step.contains("spctl --master-disable"), "\(r.id): Gatekeeper and quarantine stay")
                }
            case .bundled:
                #expect(Self.permissive.contains(r.license.spdx), "\(r.id): what Glimmer bundles is never GPL or non-commercial")
            }
        }
        #expect(Set(Requirement.all.map(\.id)).count == Requirement.all.count, "ids are unique")
    }

    @Test func everyOnDeviceModelIsAnInAppEntry() {
        for model in OnDeviceModel.allCases {
            guard case .inApp = model.requirement.install else { Issue.record("\(model) isn't downloaded in the app"); continue }
            #expect(Requirement.named(model.requirement.id) == model.requirement)
            #expect(OnDeviceModel.with(requirement: model.requirement.id) == model)
            #expect(!model.packages.isEmpty)
        }
    }

    /// An operation that can answer `model_missing` has entries: every op in the window's step
    /// code whose case calls a function that loads a downloaded model.
    @Test func everyOperationThatNeedsAModelHasAnEntry() throws {
        let app = Self.repo.appending(path: "App")
        let sources = try FileManager.default.contentsOfDirectory(atPath: app.path).filter { $0.hasSuffix(".swift") }
            .map { try String(contentsOf: app.appending(path: $0), encoding: .utf8) }.joined(separator: "\n")
        // The functions that load a downloaded model, by name.
        var loaders: Set<String> = []
        let functions = sources.components(separatedBy: "\n    func ").dropFirst()
        for body in functions {
            let name = String(body.prefix { $0 != "(" && $0 != "<" })
            let end = body.range(of: "\n    }")?.lowerBound ?? body.endIndex
            let text = body[..<end]
            if text.contains("DepthEstimator.") || text.contains("selector.prepare(") || text.contains("ModelStore.shared.load(") { loaders.insert(name) }
        }
        // One level up: a function that calls a loader (selectSky calls performSelectSky).
        for body in functions {
            let name = String(body.prefix { $0 != "(" && $0 != "<" })
            let end = body.range(of: "\n    }")?.lowerBound ?? body.endIndex
            if loaders.contains(where: { $0 != name && body[..<end].contains($0 + "(") }) { loaders.insert(name) }
        }
        #expect(loaders.contains("performSelectSky") && loaders.contains("selectSky"), "the scan finds Select Sky (found \(loaders))")
        // Commands an agent can run (run_command) whose case in the window calls a loader.
        let registry = try String(contentsOf: Self.repo.appending(path: "Packages/GlimmerKit/Sources/GlimmerCore/CommandRegistry.swift"), encoding: .utf8)
        let session = try String(contentsOf: app.appending(path: "EditorSession.swift"), encoding: .utf8)
        let runnable = Set(AgentPlanner.runnableCommands.map(\.id.rawValue))
        for line in session.split(separator: "\n") where line.contains("case .") && line.contains(": ai.") {
            guard let call = line.split(separator: ": ai.").last?.prefix(while: { $0 != "(" }), loaders.contains(String(call)) else { continue }
            let names = line.split(separator: ":").first?.replacingOccurrences(of: "case", with: "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")) } ?? []
            for name in names {
                guard let m = registry.firstMatch(of: try Regex("static let \(name): CommandID = \"([^\"]+)\"")), let raw = m.output[1].substring else { continue }
                if runnable.contains(String(raw)) {
                    #expect(Requirement.modelsForCommands[String(raw)] != nil, "run_command \(raw) loads a downloaded model and has no entry in Requirement.modelsForCommands")
                }
            }
        }
        let agent = try String(contentsOf: app.appending(path: "AIController+Agent.swift"), encoding: .utf8)
        let cases = agent.components(separatedBy: "        case \"").dropFirst()
        for c in cases {
            let ops = c.components(separatedBy: "\":").first?.components(separatedBy: "\", \"") ?? []
            let body = c.components(separatedBy: "\n        case ").first ?? c
            guard loaders.contains(where: { body.contains($0 + "(") }) else { continue }
            for op in ops {
                let ids = Requirement.modelsForOps[op] ?? []
                #expect(!ids.isEmpty, "the op \(op) loads a downloaded model and has no entry in Requirement.modelsForOps")
                for id in ids { #expect(Requirement.named(id) != nil, "\(op) needs \(id), which isn't in the register") }
            }
        }
        for (command, ids) in Requirement.modelsForCommands {
            #expect(AgentPlanner.runnableCommands.contains { $0.id.rawValue == command }, "\(command) is a runnable command")
            for id in ids { #expect(Requirement.named(id)?.neededBy.contains("run_command \(command)") == true, "\(id) says it is needed by run_command \(command)") }
            #expect(Requirement.models(forOp: "run_command", command: command) == ids)
        }
        for (op, ids) in Requirement.modelsForOps {
            #expect(AgentPlanner.op(named: op) != nil, "\(op) is an operation")
            for id in ids { #expect(Requirement.named(id)?.neededBy.contains(op) == true, "\(id) says it is needed by \(op)") }
        }
    }

    @Test func theJSONHasTheSeriesShape() throws {
        let item = Requirement.depthAnything.json(installed: false, installedVersion: nil)
        for key in ["id", "name", "kind", "neededBy", "required", "installed", "installedVersion", "sizeBytes", "license", "source", "install"] {
            #expect(item[key] != nil, "\(key)")
        }
        #expect((item["install"] as? [String: Any])?["how"] as? String == "in_app")
        #expect((item["source"] as? [String: Any])?["commit"] as? String == Requirement.depthAnything.source.commit)
        let ollama = Requirement.ollama.json(installed: nil, installedVersion: nil)
        #expect((ollama["install"] as? [String: Any])?["how"] as? String == "by_user")
        #expect((ollama["verify"] as? [String: Any])?["minVersion"] as? String == "0.6.4")
        #expect(JSONSerialization.isValidJSONObject(["items": Requirement.installable.map { $0.json(installed: nil, installedVersion: nil) }]))
        #expect(!Requirement.installable.contains { $0.install == .bundled })
    }

    @Test func theGuideListsEveryInstallableEntry() {
        let guide = AgentAPI.guide(port: AgentAPI.preferredPort, appVersion: "0")
        #expect(guide.contains("## What Glimmer may need installed"))
        for r in Requirement.installable { #expect(guide.contains("`\(r.id)`")) }
        for r in Requirement.all where r.install == .bundled { #expect(!guide.contains("(`\(r.id)`)")) }
        #expect(guide.contains("/api/v1/requirements") && guide.contains("/api/v1/settings/open") && guide.contains("model_missing"))
    }

    /// THIRD_PARTY_NOTICES.md holds the register's tables between its markers.
    @Test func theNoticesAreTheRegister() throws {
        let file = Self.repo.appending(path: "THIRD_PARTY_NOTICES.md")
        var text = try String(contentsOf: file, encoding: .utf8)
        let begin = try #require(text.range(of: "<!-- requirements:begin"))
        let beginEnd = try #require(text.range(of: "-->\n", range: begin.upperBound..<text.endIndex))
        let end = try #require(text.range(of: "<!-- requirements:end -->"))
        let tables = Requirement.noticesTables() + "\n"
        if ProcessInfo.processInfo.environment["GLIMMER_WRITE_SITE"] == "1" {
            text.replaceSubrange(beginEnd.upperBound..<end.lowerBound, with: tables)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        let marker = try #require(onDisk.range(of: "<!-- requirements:begin"))
        let b = try #require(onDisk.range(of: "-->\n", range: marker.upperBound..<onDisk.endIndex))
        let e = try #require(onDisk.range(of: "<!-- requirements:end -->"))
        #expect(String(onDisk[b.upperBound..<e.lowerBound]) == tables, "THIRD_PARTY_NOTICES.md is out of date: run scripts/export-agents-guide.sh")
    }
}
