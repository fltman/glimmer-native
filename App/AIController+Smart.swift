import AppKit
import GlimmerAI
import GlimmerCore
import GlimmerRender

/// One-click corrections worked out on the Mac itself (Core Image and Vision):
/// free, private and instant, unlike the OpenRouter jobs.
extension AIController {
    /// The analysis of the current image, computed when the image has changed
    /// since the last one. Flattening and analysis run off the main thread (like
    /// the navigator), so this never stalls the canvas, even on huge documents.
    func currentInsights() async throws -> SmartAnalysis.Insights {
        let key = documentKey(session.state)
        if key == insightsKey, let insights { return insights }
        let snapshot = session.state
        let metal = try self.metal
        let found = try await Task.detached(priority: .userInitiated) {
            SmartAnalysis.insights(of: try ImageExporter.flattenedSRGB(snapshot, context: metal))
        }.value
        insights = found
        insightsKey = key
        return found
    }

    /// Runs `then` with the current analysis; errors are reported.
    func withInsights(_ then: @escaping @MainActor (SmartAnalysis.Insights) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do { then(try await self.currentInsights()) } catch { self.session.report(error) }
        }
    }

    /// Image analysis for the omnibar, without side effects.
    func refreshInsights() {
        guard !session.isUntouchedBlank else { return }
        insightsTask?.cancel()
        insightsTask = Task { [weak self] in _ = try? await self?.currentInsights() }
    }

    func autoEnhance() {
        Task { [weak self] in
            guard let self else { return }
            do {
                if try await !self.performAutoEnhance() {
                    self.session.showToast(String(localized: "The image already looks balanced. Auto Enhance found nothing to change."))
                }
            } catch {
                self.session.report(error)
            }
        }
    }

    /// Auto Enhance: Core Image's automatic tone and colour corrections as an
    /// editable group of adjustment layers at the top of the stack. Returns
    /// false when the image needs nothing.
    @discardableResult
    func performAutoEnhance() async throws -> Bool {
        let recipe = try await currentInsights().enhance
        let adjustments = recipe.adjustments
        guard recipe.isNoticeable, !adjustments.isEmpty else { return false }
        let children = adjustments.map { Layer(name: $0.kind.title, content: .adjustment($0)) }
        let group = Layer(name: String(localized: "Auto Enhance"), blendMode: .passThrough,
                          content: .group(LayerGroup(children: children, isExpanded: false)))
        session.document.edit("Auto Enhance", undoManager: session.undoManager) {
            $0.activeLayerID = $0.layers.last?.id
            $0.insertLayerAboveActive(group)
        }
        return true
    }

    /// Auto Straighten: finds a tilted horizon and opens Crop with the box
    /// rotated to level it, so the result can be checked before it's applied.
    func autoStraighten() {
        withInsights { [weak self] insights in
            guard let self else { return }
            guard let tilt = insights.horizonDegrees else {
                self.session.showToast(String(localized: "Glimmer found no tilted horizon to straighten."))
                return
            }
            if self.session.tool != .crop { self.session.tool = .crop } else { self.session.beginCrop() }
            // A horizon rising to the right needs the box turned the same way (counterclockwise on screen).
            self.session.setCropAngle(degrees: -tilt)
        }
    }

    /// Suggest Crop: frames the salient part of the image at the crop's aspect.
    func suggestCrop() {
        withInsights { [weak self] insights in
            guard let self else { return }
            let s = self.session
            if s.tool != .crop { s.tool = .crop }
            guard var c = s.cropSession else { return }
            guard let salient = insights.salientRect,
                  let r = SmartAnalysis.suggestedCrop(salient: salient, imageWidth: s.state.width,
                                                      imageHeight: s.state.height, aspect: c.aspect) else {
                s.showToast(String(localized: "The whole image already frames the subject well."))
                return
            }
            c.angle = 0
            c.baseSize = nil
            c.pivot = .zero
            c.rect = CGRectLike(x0: r.minX, y0: r.minY, x1: r.maxX, y1: r.maxY)
            s.cropSession = c
        }
    }

    func autoColor() {
        Task { [weak self] in
            guard let self else { return }
            do {
                if try await !self.performAutoColor() { self.session.showToast(String(localized: "No colour cast to correct.")) }
            } catch {
                self.session.report(error)
            }
        }
    }

    /// Auto Color: neutralises a colour cast with a Color Balance layer.
    /// Returns false when there is no cast worth correcting.
    @discardableResult
    func performAutoColor() async throws -> Bool {
        guard let cast = try await currentInsights().enhance.colorCast,
              SmartAnalysis.isNoticeableCast(cast, threshold: 0.012) else { return false }
        session.document.edit("Auto Color", undoManager: session.undoManager) {
            $0.activeLayerID = $0.layers.last?.id
            $0.insertLayerAboveActive(Layer(name: String(localized: "Auto Color"),
                                            content: .adjustment(SmartAnalysis.castCorrection(cast))))
        }
        return true
    }

    func selectPeople() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.performSelectPeople()
            } catch SegmentationError.noSubject {
                self.session.showToast(String(localized: "No people found in the image."))
            } catch {
                self.session.report(error)
            }
        }
    }

    /// Select People: Vision's person segmentation of the whole image.
    func performSelectPeople() async throws {
        let snapshot = session.state
        let metal = try self.metal
        let selection = try await Task.detached(priority: .userInitiated) {
            let mask = try SubjectSegmentation.peopleMask(of: try ImageExporter.flattenedSRGB(snapshot, context: metal))
            return Selection.from(mask: mask.values.map { $0 / 255 }, rect: snapshot.bounds)
        }.value
        session.document.edit("Select People", undoManager: session.undoManager) { $0.selection = selection }
    }

    /// Reads the text in the image (Live Text, on this Mac).
    private func recognizeText(_ then: @escaping @MainActor ([ImageText.Line], CGImage) -> Void) {
        let snapshot = session.state
        guard let metal = try? self.metal else { return }
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<([ImageText.Line], CGImage), Error> in
                Result {
                    let image = try ImageExporter.flattenedSRGB(snapshot, context: metal)
                    return (try ImageText.lines(in: image), image)
                }
            }.value
            guard let self else { return }
            switch result {
            case .success(let (lines, image)):
                if lines.isEmpty {
                    self.session.showToast(String(localized: "Glimmer found no text in the image."))
                } else {
                    then(lines, image)
                }
            case .failure(let error):
                self.session.report(error)
            }
        }
    }

    func copyImageText() {
        recognizeText { [weak self] lines, _ in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(ImageText.plainText(lines), forType: .string)
            self?.session.showToast(String(localized: "Copied \(lines.count) lines of text."))
        }
    }

    /// Image Text to Layers: every line of text becomes an editable text layer
    /// at its place, sized to cover it and coloured like it, in one group.
    func textToLayers() {
        recognizeText { [weak self] lines, image in
            guard let self else { return }
            let layers = lines.map { ImageText.textLayer(for: $0, in: image) }
            let group = Layer(name: String(localized: "Text from Image"), blendMode: .passThrough,
                              content: .group(LayerGroup(children: layers, isExpanded: true)))
            self.session.document.edit("Image Text to Layers", undoManager: self.session.undoManager) {
                $0.activeLayerID = $0.layers.last?.id
                $0.insertLayerAboveActive(group)
            }
            self.session.showToast(String(localized: "\(lines.count) text layers added. Paint out or remove the original text underneath to replace it."))
        }
    }

    /// Commands that suit this image, best first, for the omnibar.
    var smartSuggestions: [CommandID] {
        guard let insights, insightsKey == documentKey(session.state) else { return [] }
        var ids: [CommandID] = []
        if insights.horizonDegrees != nil { ids.append(.autoStraighten) }
        if insights.enhance.isNoticeable, insights.tone.isFlat || insights.tone.isDark || insights.tone.isBright || insights.tone.isMuted {
            ids.append(.autoEnhance)
        }
        if insights.enhance.isNoticeable == false, SmartAnalysis.isNoticeableCast(insights.enhance.colorCast) {
            ids.append(.autoColor)
        }
        if insights.faceCount > 0 {
            ids.append(.selectPeople)
            ids.append(.aiLensBlur)
        }
        if insights.hasText { ids.append(.textToLayers) }
        if let salient = insights.salientRect,
           SmartAnalysis.suggestedCrop(salient: salient, imageWidth: session.state.width, imageHeight: session.state.height,
                                       aspect: nil) != nil {
            ids.append(.suggestCrop)
        }
        if insights.enhance.isNoticeable, !ids.contains(.autoEnhance) { ids.append(.autoEnhance) }
        return Array(ids.prefix(4))
    }
}
