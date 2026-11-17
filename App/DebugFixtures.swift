#if DEBUG
import AppKit
import Foundation
import GlimmerAI
import GlimmerCore
import GlimmerRender

/// States for accessibility checks (debug builds only): panels with content in them, and the
/// sheets and alerts that otherwise need a key, a sibling app or a failure to appear.
/// `POST /api/v1/debug/fixture {"name": …}` puts one up; `scripts/test-accessibility.sh` reads
/// each through the accessibility API. A crash on 2026-11-16 was only reachable with a
/// message in the Assistant, which the audits of empty panels never had.
extension AIController {
    /// Puts the named state up. Returns false for a name that isn't one.
    func showFixture(_ name: String) -> Bool {
        let s = session
        switch name {
        case "clear":
            s.textNotice = nil; s.healWarning = nil; s.errorMessage = nil
            s.isImageSizePresented = false; s.isCanvasSizePresented = false; s.isPSDExportPresented = false; s.isImportReportPresented = false
            s.linkedImage = nil; s.brokenLink = nil
            clearFixtureJobs()   // a running job left from the job-list state put its spinner in every later picture
        case "panel:layers", "panel:paths", "panel:channels", "panel:history", "panel:ai":
            // The side panel, on the named tab.
            let tab = EditorSession.InspectorTab.allCases.first { "panel:" + $0.rawValue.lowercased() == name }!
            s.showLayersPanel = true
            s.inspectorTab = tab
            if tab == .ai { s.aiSection = .assistant }
        case "assistant":
            s.showLayersPanel = true; s.inspectorTab = .ai; s.aiSection = .assistant
            // A conversation with every kind of entry: a request, an answer, a plan (one step failed), an error, a refusal.
            var withPlan = Message(fromUser: false, text: "Here's the plan.")
            let steps = [AgentStep(op: "add_adjustment", params: ["type": .string("black_white")], rationale: "Make it monochrome."),
                         AgentStep(op: "add_text", params: ["text": .string("Hello"), "position": .string("top")], rationale: "The title."),
                         AgentStep(op: "crop", params: ["aspect": .string("16:9")], rationale: "Widescreen.")]
            withPlan.plan = AgentPlan(steps: steps, message: "Here's the plan.", droppedOps: ["make_wide"])
            messages = [
                Message(fromUser: true, text: "Make it black and white, add the text Hello at the top and crop to 16:9"),
                withPlan,
                Message(fromUser: true, text: "And make the sky pink"),
                Message(fromUser: false, text: "Berget answered HTTP 404: The model `glm-9` does not exist or has been retired."),
                Message(fromUser: false, text: "Claude declined this request (cyber). Nothing was changed."),
                Message(fromUser: false, text: String(localized: "\("qwen3:8b") can't take pictures, so the Assistant plans without looking at the document.")),
            ]
            stepStatus = [steps[0].id: .done, steps[1].id: .failed("No font named “Nope” is installed."), steps[2].id: .skipped]
            planStatus = [withPlan.id: .failed]
            // As the app itself writes them: the plan stopped part-way, and the model had planned a step Glimmer doesn't have.
            messages[1].text = whatWasDone(steps) + " " + String(localized: "The assistant also planned steps Glimmer doesn't have (\("make_wide")); they are left out.")
        case "waiting":
            // A plan whose step the request doesn't name, and a command the on-device model chose unasked: both wait for Run.
            s.showLayersPanel = true; s.inspectorTab = .ai; s.aiSection = .assistant
            var planned = Message(fromUser: false, text: "Here is a poem as a text layer. " + String(localized: "Some of these steps aren't named in what you asked, so the plan waits for Run."))
            let step = AgentStep(op: "add_text", params: ["text": .string("The sea is wide")], rationale: "The poem.")
            planned.plan = AgentPlan(steps: [step], message: nil)
            var command = Message(fromUser: false, text: String(localized: "I think you mean \(String(localized: "Rasterize Layer")). You didn't name it, so it waits for you."))
            command.pendingCommand = CommandID.rasterizeLayer.rawValue   // a command that exists (the fixture named one that didn't)
            // An extra the model added beside what was asked: offered, and it waits.
            let extra = AgentStep(op: "auto_enhance")
            var offer = Message(fromUser: false, text: String(localized: "The assistant also suggests \(String(localized: "Auto Enhance")), which you didn't ask for. Run it now on the picture as it is?"))
            offer.plan = AgentPlan(steps: [extra])
            messages = [Message(fromUser: true, text: "Write a poem about the sea"), planned, Message(fromUser: true, text: "tidy up"), command, offer]
            stepStatus = [step.id: .pending, extra.id: .pending]
            planStatus = [planned.id: .proposed, offer.id: .proposed]
        case "paidPlan":
            // A plan with a paid step: "Uses AI credits", the line that the price is not known, and (until made) the once-per-service tick; Run is grey.
            s.showLayersPanel = true; s.inspectorTab = .ai; s.aiSection = .assistant
            let paid = AgentStep(op: "generate_layer", params: ["prompt": .string("a red bird on the fence")], rationale: "The bird.")
            var planned = Message(fromUser: false, text: "Adding a red bird as a new layer.")
            planned.plan = AgentPlan(steps: [paid], message: nil)
            messages = [Message(fromUser: true, text: "Add a red bird on the fence"), planned]
            stepStatus = [paid.id: .pending]
            planStatus = [planned.id: .proposed]
        case "refusedPlan":
            // A plan with a step its operation would refuse (a setting the adjustment doesn't have): shown, said to be unrunnable, no Run.
            s.showLayersPanel = true; s.inspectorTab = .ai; s.aiSection = .assistant
            let first = AgentStep(op: "crop", params: ["aspect": .string("1:1")], rationale: "Square.")
            let second = AgentStep(op: "add_adjustment", params: ["type": .string("exposure"), "params": .object(["brightness": .number(0.3)])],
                                   rationale: "Brighter. (\(StepParameters.strayNote): brightness)")
            let stray = StepParameters.stray(in: second)
            var refused = Message(fromUser: false, text: "Cropping square and brightening. " + String(localized: "The plan asks \(String(localized: String.LocalizationValue(stray?.subject ?? ""))) for a setting it doesn't have (\(stray?.name ?? "")), so it can't run. Nothing was changed. Ask again, perhaps in other words."))
            refused.exactWords = stray?.message
            refused.plan = AgentPlan(steps: [first, second])
            messages = [Message(fromUser: true, text: "Make it square and brighter"), refused]
            stepStatus = [first.id: .skipped, second.id: .skipped]
            planStatus = [refused.id: .failed]
        case "jobs":
            s.showLayersPanel = true; s.inspectorTab = .ai
            showFixtureJobs()
        case "firstUse":
            let provider = AIProvider.named("berget")!
            s.textNotice = TextNotice(kind: .firstUse, title: String(localized: "Send this to \(provider.name)?"),
                                      message: Self.textNotice(for: provider, sendsPictures: true) + " " + String(localized: "You can read this again in Settings › AI."), proceed: nil)
        case "firstUseNoPictures":
            let provider = AIProvider.named("grunden")!
            s.textNotice = TextNotice(kind: .firstUse, title: String(localized: "Send this to \(provider.name)?"),
                                      message: Self.textNotice(for: provider, sendsPictures: false) + " " + String(localized: "You can read this again in Settings › AI."), proceed: nil)
        case "cantSee":
            s.textNotice = TextNotice(kind: .cantSee, title: String(localized: "This model can't look at pictures"),
                                      message: String(localized: "\("Berget") lists \("mistralai/Mistral-Small-3.2-24B-Instruct-2506") as a model without picture input, and this needs to see your document. Nothing was sent. Choose a model that takes pictures in Settings › AI."))
        case "healWarning":
            s.healWarning = PersonMessage.text("The area is 203 px across at its thickest. Heal Selection gives good results up to about 120 px; beyond that the fill may smear or repeat.")
        case "error":
            s.errorMessage = String(localized: "Couldn't save \("photo.png"): \("The file “photo.png” couldn’t be opened because you don’t have permission to view it.")")
        case "cover":
            // An opaque window of this app laid exactly over the document's window, to see that
            // what only moves while it is seen (the icon's glow) stands still when covered.
            guard let frame = s.canvasWindow?.frame else { return false }
            let cover = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            cover.isOpaque = true; cover.backgroundColor = .black; cover.isReleasedWhenClosed = false
            cover.setFrame(frame, display: true)
            cover.orderFront(nil)
        case "rawDevelop":
            #if GLIMMER_RAW
            guard s.activeLayer?.raw != nil else { return false }
            s.isRawDevelopPresented = true
            #endif
        case "psdExport":
            #if GLIMMER_PSD
            s.isPSDExportPresented = true
            #endif
        case "imageSize":
            s.isImageSizePresented = true
        case "canvasSize":
            s.isCanvasSizePresented = true
        case "splash":
            DocumentOpener.shared.showAgentSplash()
        case "linked":
            s.brokenLink = nil
            if let link = LinkedImage(url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("frame-0412.png"), requester: "Flimmer") {
                s.linkedImage = link
            }
        case "brokenLink":
            s.linkedImage = nil
            s.brokenLink = (DocumentLink(bookmark: nil, path: "/tmp/frame-0412.png", requester: "Flimmer"),
                            String(localized: "\("frame-0412.png") is no longer where it was, so Glimmer can't save it back to \("Flimmer")."))
        default:
            return false
        }
        return true
    }
}
#endif
