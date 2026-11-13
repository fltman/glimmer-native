import Foundation
import Testing
@testable import GlimmerAI

@Suite struct OnDeviceRouterTests {
    let candidates = [
        OnDeviceRouter.Candidate(id: "adjustment.invert", title: "Invert", subtitle: "Adjustment"),
        OnDeviceRouter.Candidate(id: "image.flipHorizontal", title: "Flip Canvas Horizontal", subtitle: "Image"),
        OnDeviceRouter.Candidate(id: "layer.new", title: "New Layer", subtitle: "Layer"),
    ]

    @Test func unknownIdsFallBackToTheAssistant() {
        let route = OnDeviceRouter.Route(action: .run, optionID: "image.explode", prompt: "")
        #expect(OnDeviceRouter.decision(route, text: "explode", candidates: candidates) == .assistant)
        let ok = OnDeviceRouter.Route(action: .run, optionID: " layer.new ", prompt: "")
        #expect(OnDeviceRouter.decision(ok, text: "new layer", candidates: candidates) == .run("layer.new"))
        let gen = OnDeviceRouter.Route(action: .generate, optionID: "", prompt: "")
        #expect(OnDeviceRouter.decision(gen, text: "a red fox", candidates: candidates) == .generate("a red fox"))
    }
}

/// Runs Apple's on-device model; skipped where Apple Intelligence is unavailable.
@Suite(.enabled(if: OnDeviceRouter.isAvailable))
struct LiveOnDeviceRouterTests {
    let candidates = OnDeviceRouterTests().candidates

    @Test func routesASingleCommand() async throws {
        let d = try await OnDeviceRouter.route("flip the canvas horizontally", candidates: candidates)
        print("flip → \(d)")
        #expect(d == .run("image.flipHorizontal"))
    }

    @Test func routesANewPicture() async throws {
        let d = try await OnDeviceRouter.route("make an image of a lighthouse in a storm", candidates: candidates)
        print("lighthouse → \(d)")
        guard case .generate(let prompt) = d else { Issue.record("expected generate, got \(d)"); return }
        #expect(prompt.localizedCaseInsensitiveContains("lighthouse"))
    }

    @Test func multiStepEditsGoToTheAssistant() async throws {
        let d = try await OnDeviceRouter.route("make it warmer, add a vignette and remove the person on the left",
                                               candidates: candidates)
        print("multi → \(d)")
        #expect(d == .assistant)
    }
}
