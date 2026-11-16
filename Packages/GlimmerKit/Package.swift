// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Heal Selection can be left out of a release: Config/Features.xcconfig decides, for this
// package and for the app alike. Debug builds (and so the tests) always compile it.
// Xcode keeps a package manifest's result until the manifest's own text changes, so a changed
// switch alone would not reach a release build. scripts/apply-features.py rewrites the next
// line from Config/Features.xcconfig; that change is what makes Xcode read the file again.
// features: HEAL=NO PSD=YES RAW=NO
let features = (try? String(contentsOfFile: Context.packageDirectory + "/../../Config/Features.xcconfig", encoding: .utf8)) ?? ""
let releaseHasHeal = features.split(separator: "\n").contains { $0.replacingOccurrences(of: " ", with: "") == "GLIMMER_HEAL=YES" }
// Photoshop import is switched the same way (GLIMMER_PSD).
let releaseHasPSD = features.split(separator: "\n").contains { $0.replacingOccurrences(of: " ", with: "") == "GLIMMER_PSD=YES" }
let releaseHasRAW = features.split(separator: "\n").contains { $0.replacingOccurrences(of: " ", with: "") == "GLIMMER_RAW=YES" }
let healSettings: [SwiftSetting] = [.define("GLIMMER_HEAL", .when(configuration: .debug)), .define("GLIMMER_PSD", .when(configuration: .debug)), .define("GLIMMER_RAW", .when(configuration: .debug))]
    + (releaseHasRAW ? [.define("GLIMMER_RAW", .when(configuration: .release))] : [])
    + (releaseHasHeal ? [.define("GLIMMER_HEAL", .when(configuration: .release))] : [])
    + (releaseHasPSD ? [.define("GLIMMER_PSD", .when(configuration: .release))] : [])

let package = Package(
    name: "GlimmerKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "GlimmerCore", targets: ["GlimmerCore"]),
        .library(name: "GlimmerRender", targets: ["GlimmerRender"]),
        .library(name: "GlimmerTools", targets: ["GlimmerTools"]),
        .library(name: "GlimmerAI", targets: ["GlimmerAI"]),
        .library(name: "GlimmerHeal", targets: ["GlimmerHeal"]),
    ],
    targets: [
        // Document model, tiles, undo, file format. Pure Swift, no Metal.
        .target(name: "GlimmerCore", swiftSettings: healSettings),
        // Metal compositor and canvas presentation.
        .target(
            name: "GlimmerRender",
            dependencies: ["GlimmerCore"],
            resources: [.process("Shaders")],
            swiftSettings: healSettings
        ),
        // Interactive tools (brush, selection, transform, ...).
        .target(name: "GlimmerTools", dependencies: ["GlimmerCore", "GlimmerRender"]),
        // OpenRouter client, AI pipelines, on-device models.
        .target(
            name: "GlimmerAI",
            dependencies: ["GlimmerCore"],
            // Real-ESRGAN realesr-general-x4v3 (BSD-3-Clause), converted by scripts/convert-models/realesrgan.py.
            resources: [.copy("Resources/RealESRGAN.mlmodelc")],
            swiftSettings: healSettings
        ),
        // Heal Selection: fills an area from its surroundings. Pure Swift, no model; empty
        // when the switch is off (docs/PATENTS.md).
        // Optimised in debug builds too: the texture fill is a tight loop that is some fifty
        // times slower unoptimised, and the test copies of the app are debug builds.
        .target(name: "GlimmerHeal", swiftSettings: healSettings + [.unsafeFlags(["-O"], .when(configuration: .debug))]),

        // For the tests only: refuses, and fails the run on, any request to a host other than this
        // Mac that a test has not replaced. The C part loads it before any test runs.
        .target(name: "NetworkGuardLoader", path: "Tests/Support/NetworkGuardLoader"),
        .target(name: "NetworkGuard", dependencies: ["NetworkGuardLoader"], path: "Tests/Support/NetworkGuard"),
        // For the tests only: writes Photoshop files to read back and to damage.
        .target(name: "PSDTestSupport", dependencies: ["GlimmerCore"], path: "Tests/Support/PSDTestSupport"),

        .testTarget(name: "GlimmerCoreTests", dependencies: ["GlimmerCore", "NetworkGuard", "PSDTestSupport"]),
        .testTarget(name: "GlimmerRenderTests", dependencies: ["GlimmerRender", "NetworkGuard", "PSDTestSupport"]),
        .testTarget(name: "GlimmerAITests", dependencies: ["GlimmerAI", "NetworkGuard"]),
        .testTarget(name: "GlimmerToolsTests", dependencies: ["GlimmerTools", "NetworkGuard"]),
        .testTarget(name: "GlimmerHealTests", dependencies: ["GlimmerHeal", "NetworkGuard"], swiftSettings: healSettings),
    ],
    swiftLanguageModes: [.v6]
)
