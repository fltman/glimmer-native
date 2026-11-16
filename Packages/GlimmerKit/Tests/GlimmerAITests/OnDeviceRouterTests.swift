import Foundation
import Testing
@testable import GlimmerAI

@Suite struct OnDeviceRouterTests {
    let candidates = [
        OnDeviceRouter.Candidate(id: "adjustment.invert", title: "Invert", subtitle: "Adjustment"),
        OnDeviceRouter.Candidate(id: "image.flipHorizontal", title: "Flip Canvas Horizontal", subtitle: "Image"),
        OnDeviceRouter.Candidate(id: "layer.new", title: "New Layer", subtitle: "Layer"),
    ]

    @Test func compoundRequestsAreNeverASingleCommand() {
        for text in ["make it a moody black and white with a vignette", "invert, then flip it", "warmer and sharper",
                     "gör den svartvit med vinjett", "ljusare och varmare"] {
            #expect(OnDeviceRouter.isCompound(text), "\(text)")
            let route = OnDeviceRouter.Route(action: .run, optionID: "adjustment.invert", prompt: "")
            #expect(OnDeviceRouter.decision(route, text: text, candidates: candidates) == .assistant)
        }
        for text in ["invert the colors", "make it black and white", "new layer", "gör den svart och vit"] {
            #expect(!OnDeviceRouter.isCompound(text), "\(text)")
        }
    }

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
/// Serialized: four model sessions at once, beside the rest of the suite, made the
/// system's content check time out (SensitiveContentAnalysisML error 15).
/// These load Apple's on-device model, so they are run on purpose and one model at a time
/// for the whole series: `scripts/evaluate-models.sh on-device` (the model lock). The
/// ordinary run skips them.
@Suite(.enabled(if: OnDeviceRouter.isAvailable && ProcessInfo.processInfo.environment["GLIMMER_ON_DEVICE_TESTS"] == "1"), .serialized)
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

    @Test func aGeneralFixGoesToAutoEnhance() async throws {
        let options = [
            OnDeviceRouter.Candidate(id: "image.autoEnhance", title: "Auto Enhance", subtitle: "Image"),
            OnDeviceRouter.Candidate(id: "layer.adjustment.hue_saturation", title: "Hue/Saturation", subtitle: "Adjustment"),
            OnDeviceRouter.Candidate(id: "layer.adjustment.vibrance", title: "Vibrance", subtitle: "Adjustment"),
            OnDeviceRouter.Candidate(id: "layer.adjustment.invert", title: "Invert", subtitle: "Adjustment"),
        ]
        for request in ["fix the colors", "improve the photo"] {
            let d = try await OnDeviceRouter.route(request, candidates: options)
            print("\(request) → \(d)")
            #expect(d == .run("image.autoEnhance"))
        }
    }

    @Test func multiStepEditsGoToTheAssistant() async throws {
        let d = try await OnDeviceRouter.route("make it warmer, add a vignette and remove the person on the left",
                                               candidates: candidates)
        print("multi → \(d)")
        #expect(d == .assistant)
    }
}
