import Foundation
@testable import GlimmerAI
import Testing

/// site/agents.md is the agent guide the app serves at GET /glimmer, exported
/// from the same register. This test fails when it's out of date; regenerate
/// with scripts/export-agents-guide.sh (or GLIMMER_WRITE_SITE=1 swift test --filter SiteExportTests).
@Suite struct SiteExportTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()  // GlimmerAITests
        .deletingLastPathComponent().deletingLastPathComponent()  // GlimmerKit
        .deletingLastPathComponent().deletingLastPathComponent()  // repo

    /// MARKETING_VERSION from project.yml.
    static var version: String {
        let yml = (try? String(contentsOf: repo.appending(path: "project.yml"), encoding: .utf8)) ?? ""
        for line in yml.split(separator: "\n") where line.contains("MARKETING_VERSION:") {
            return line.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) } ?? "?"
        }
        return "?"
    }

    /// No tracked file names a home folder (a user name in a path is private, and such a path
    /// only works on one Mac). Use an environment variable or a path relative to the repository.
    @Test func noTrackedFileContainsAHomePath() throws {
        let needle = "/" + "Users" + "/"
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", Self.repo.path, "grep", "-l", "-I", "-F", needle]
        let out = Pipe()
        git.standardOutput = out
        git.standardError = Pipe()
        try git.run()
        let found = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        git.waitUntilExit()
        // git grep exits 1 when nothing matches; anything else means it couldn't look.
        #expect(git.terminationStatus == 1 || git.terminationStatus == 0)
        #expect(found.isEmpty, "these tracked files contain a home path: \(found)")
    }

    @Test func agentGuideOnTheSiteMatchesTheApp() throws {
        let file = Self.repo.appending(path: "site/agents.md")
        // The site describes what a release has (Config/Features.xcconfig), not this debug build.
        let features = try String(contentsOf: Self.repo.appending(path: "Config/Features.xcconfig"), encoding: .utf8)
        let releaseHasHeal = features.split(separator: "\n").contains { $0.replacingOccurrences(of: " ", with: "") == "GLIMMER_HEAL=YES" }
        let guide = AgentAPI.guide(port: AgentAPI.preferredPort, appVersion: Self.version, heal: releaseHasHeal)
        #expect(guide.contains("heal_selection") == releaseHasHeal)
        #if GLIMMER_HEAL
        #expect(AgentAPI.guide(port: AgentAPI.preferredPort, appVersion: Self.version, heal: true).contains("heal_selection"))
        #expect(AgentAPI.operations.contains { $0["name"] as? String == "heal_selection" && $0["tier"] as? String == "advanced" && $0["paid"] as? Bool == false })
        #endif
        if ProcessInfo.processInfo.environment["GLIMMER_WRITE_SITE"] == "1" {
            try guide.write(to: file, atomically: true, encoding: .utf8)
        }
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        #expect(onDisk == guide, "site/agents.md is out of date: run scripts/export-agents-guide.sh")
    }

    /// The table of services in the manual is the app's own list (`AIProvider`), between two markers.
    @Test func theManualsTableOfServicesMatchesTheApp() throws {
        let file = Self.repo.appending(path: "site/manual/11-ai-with-openrouter.md")
        var text = try String(contentsOf: file, encoding: .utf8)
        let begin = try #require(text.range(of: "<!-- providers:begin"))
        let beginEnd = try #require(text.range(of: "-->\n", range: begin.upperBound..<text.endIndex))
        let end = try #require(text.range(of: "<!-- providers:end -->"))
        let table = AIProvider.manualTable() + "\n"
        if ProcessInfo.processInfo.environment["GLIMMER_WRITE_SITE"] == "1" {
            text.replaceSubrange(beginEnd.upperBound..<end.lowerBound, with: table)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        let marker = try #require(onDisk.range(of: "<!-- providers:begin"))
        let b = try #require(onDisk.range(of: "-->\n", range: marker.upperBound..<onDisk.endIndex))
        let e = try #require(onDisk.range(of: "<!-- providers:end -->"))
        #expect(String(onDisk[b.upperBound..<e.lowerBound]) == table, "the manual's table of services is out of date: run scripts/export-agents-guide.sh")
    }

    /// The manual and FAQ say what the release build has (Config/Features.xcconfig).
    @Test func manualFollowsFeatures() throws {
        let p = Process()
        p.executableURL = Self.repo.appending(path: "scripts/apply-features.py")
        p.arguments = ["--check"]
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0, "\(String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")")
    }
}
