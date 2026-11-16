// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Heal Selection can be left out of a release: Config/Features.xcconfig decides, for this
// package and for the app alike. Debug builds (and so the tests) always compile it.
let features = (try? String(contentsOfFile: Context.packageDirectory + "/../../Config/Features.xcconfig", encoding: .utf8)) ?? ""
let releaseHasHeal = features.split(separator: "\n").contains { $0.replacingOccurrences(of: " ", with: "") == "GLIMMER_HEAL=YES" }
let healSettings: [SwiftSetting] = [.define("GLIMMER_HEAL", .when(configuration: .debug))]
    + (releaseHasHeal ? [.define("GLIMMER_HEAL", .when(configuration: .release))] : [])

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
            resources: [.process("Shaders")]
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

        .testTarget(name: "GlimmerCoreTests", dependencies: ["GlimmerCore"]),
        .testTarget(name: "GlimmerRenderTests", dependencies: ["GlimmerRender"]),
        .testTarget(name: "GlimmerAITests", dependencies: ["GlimmerAI"]),
        .testTarget(name: "GlimmerToolsTests", dependencies: ["GlimmerTools"]),
        .testTarget(name: "GlimmerHealTests", dependencies: ["GlimmerHeal"], swiftSettings: healSettings),
    ],
    swiftLanguageModes: [.v6]
)
