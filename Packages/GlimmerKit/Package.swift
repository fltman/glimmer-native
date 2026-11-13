// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GlimmerKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "GlimmerCore", targets: ["GlimmerCore"]),
        .library(name: "GlimmerRender", targets: ["GlimmerRender"]),
        .library(name: "GlimmerTools", targets: ["GlimmerTools"]),
        .library(name: "GlimmerAI", targets: ["GlimmerAI"]),
    ],
    targets: [
        // Document model, tiles, undo, file format. Pure Swift, no Metal.
        .target(name: "GlimmerCore"),
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
            resources: [.copy("Resources/RealESRGAN.mlmodelc")]
        ),

        .testTarget(name: "GlimmerCoreTests", dependencies: ["GlimmerCore"]),
        .testTarget(name: "GlimmerRenderTests", dependencies: ["GlimmerRender"]),
        .testTarget(name: "GlimmerAITests", dependencies: ["GlimmerAI"]),
        .testTarget(name: "GlimmerToolsTests", dependencies: ["GlimmerTools"]),
    ],
    swiftLanguageModes: [.v6]
)
