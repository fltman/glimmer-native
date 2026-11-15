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
        let guide = AgentAPI.guide(port: AgentAPI.preferredPort, appVersion: Self.version)
        if ProcessInfo.processInfo.environment["GLIMMER_WRITE_SITE"] == "1" {
            try guide.write(to: file, atomically: true, encoding: .utf8)
        }
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        #expect(onDisk == guide, "site/agents.md is out of date: run scripts/export-agents-guide.sh")
    }
}
