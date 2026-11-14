import CoreGraphics
import CryptoKit
import Foundation
import GlimmerCore

/// An image-generating model: text plus input images in, one image out.
public protocol ImageModel: Sendable {
    func generate(prompt: String, images: [RGBAImage], seed: Int?) async throws -> AIImageResult
}

public struct AIImageResult: Sendable {
    public var image: RGBAImage
    public var cost: Double?

    public init(image: RGBAImage, cost: Double? = nil) {
        self.image = image
        self.cost = cost
    }
}

/// OpenRouter-backed image model with an on-disk result cache, so retrying or
/// re-running an identical request doesn't pay twice.
public struct OpenRouterImageModel: ImageModel {
    public let client: OpenRouterClient
    public let model: String
    /// Inputs are downscaled to this long side before sending.
    public let maxInputSide: Int
    public let cacheDirectory: URL?

    public init(client: OpenRouterClient, model: String, maxInputSide: Int = 2048, cacheDirectory: URL? = AIResultCache.defaultDirectory) {
        self.client = client
        self.model = model
        self.maxInputSide = maxInputSide
        self.cacheDirectory = cacheDirectory
    }

    public func generate(prompt: String, images: [RGBAImage], seed: Int?) async throws -> AIImageResult {
        let pngs = images.map { $0.limited(toMaxSide: maxInputSide).pngData() }
        let cache = cacheDirectory.map(AIResultCache.init)
        let key = AIResultCache.key(model: model, prompt: prompt, images: pngs, seed: seed)
        if let hit = cache?.load(key), let image = try? ImageImporter.image(from: hit) {
            return AIImageResult(image: RGBAImage(image), cost: 0)
        }
        let response = try await client.imageCompletion(model: model, text: prompt, images: pngs, seed: seed)
        let image = try ImageImporter.image(from: response.imageData)
        cache?.store(response.imageData, key: key)
        return AIImageResult(image: RGBAImage(image), cost: response.cost)
    }
}

public struct AIResultCache: Sendable {
    public static let defaultDirectory: URL? = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first?.appending(path: "AIResults")

    let directory: URL

    init(_ directory: URL) {
        self.directory = directory
    }

    static func key(model: String, prompt: String, images: [Data], seed: Int?) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(model.utf8))
        hasher.update(data: Data(prompt.utf8))
        for image in images { hasher.update(data: Data(SHA256.hash(data: image))) }
        hasher.update(data: Data(String(seed ?? -1).utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func load(_ key: String) -> Data? {
        try? Data(contentsOf: directory.appending(path: key + ".png"))
    }

    func store(_ data: Data, key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appending(path: key + ".png"), options: .atomic)
    }
}

/// The web app's AI pipelines, ported (`workers/aips/pipelines`, `tasks`).
public enum AIPipelines {
    // MARK: Generate

    public static func generate(prompt: String, negative: String? = nil, width: Int, height: Int,
                                seed: Int? = nil, model: ImageModel) async throws -> AIImageResult {
        var text = prompt
        if let negative, !negative.isEmpty { text += "\n\nAvoid: \(negative)" }
        text += "\n\nTarget dimensions: \(width)x\(height) pixels."
        return try await model.generate(prompt: text, images: [], seed: seed)
    }

    // MARK: Edit the whole image

    /// Instruction edit of the flattened image, re-aligned to the source size.
    public static func edit(_ image: RGBAImage, instruction: String, seed: Int? = nil,
                            model: ImageModel) async throws -> AIImageResult {
        var result = try await model.generate(prompt: instruction, images: [image], seed: seed)
        result.image = result.image.resized(width: image.width, height: image.height)
        return result
    }

    // MARK: Inpaint / generative fill

    public enum InpaintMode: String, Sendable, CaseIterable {
        case fill, remove
    }

    static let maskPreamble = "You are editing the FIRST image. The SECOND image is a mask: pure white "
        + "marks the ONLY region you may change; black pixels must stay byte-for-byte "
        + "identical."

    public static func inpaintInstruction(mode: InpaintMode, prompt: String) -> String {
        let base = maskPreamble + " Do not recompose, crop, rotate or resize. Keep the framing, "
            + "perspective, lighting, colors and exposure of the unmasked area identical."
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == .remove {
            return base + " Task: REMOVE whatever object occupies the white region and "
                + "plausibly reconstruct the background that would be behind it, matching "
                + "surrounding texture, lighting and color."
                + (p.isEmpty ? "" : " The user describes what to remove or how to fill in: \(p).")
        }
        return base + " Task: replace ONLY the white region with: \(p.isEmpty ? "content that blends seamlessly with the surroundings" : p)."
    }

    public static func referenceInstruction(prompt: String) -> String {
        let base = maskPreamble + " The THIRD image is a REFERENCE showing the object to insert. "
            + "Fill ONLY the masked (white) region with the object shown in the reference "
            + "image; match its identity and appearance while adapting its scale, "
            + "perspective, lighting and color to the scene. Do not recompose, crop, "
            + "rotate or resize the FIRST image, and keep every unmasked pixel identical."
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? base : base + " Additional guidance: \(p)."
    }

    public struct InpaintResult: Sendable {
        /// The new pixels; alpha is the feathered mask so only the edited area shows.
        public var image: RGBAImage
        /// Where `image` goes in the document.
        public var origin: SIMD2<Int>
        public var cost: Double?
    }

    /// Fills or removes the selected region of `image` (the document composite).
    ///
    /// Crops the selection bounds plus 30 % context, sends crop + mask (+ reference),
    /// re-aligns, colour-matches against the untouched pixels and feathers the mask.
    public static func inpaint(image: RGBAImage, mask: GrayImage, selectionBounds: PixelRect,
                               mode: InpaintMode, prompt: String, reference: RGBAImage? = nil,
                               seed: Int? = nil, model: ImageModel) async throws -> InpaintResult {
        let roi = Imaging.clampROI(selectionBounds, width: image.width, height: image.height)
        let crop = image.cropped(to: roi)
        var cropMask = GrayImage(width: roi.width, height: roi.height, fill: 0)
        for y in 0..<roi.height {
            for x in 0..<roi.width {
                cropMask.values[y * roi.width + x] = mask.values[(roi.y + y) * mask.width + roi.x + x]
            }
        }

        let result: AIImageResult
        if let reference, mode == .fill {
            result = try await model.generate(prompt: referenceInstruction(prompt: prompt),
                                              images: [crop, cropMask.rgba, reference], seed: seed)
        } else {
            result = try await model.generate(prompt: inpaintInstruction(mode: mode, prompt: prompt),
                                              images: [crop, cropMask.rgba], seed: seed)
        }
        let aligned = result.image.resized(width: roi.width, height: roi.height)
        let matched = Imaging.colorMatch(aligned, to: crop, trusted: cropMask.inverted)
        let alpha = Imaging.featherMask(cropMask, erode: 2, blur: 3)
        // Only the (feathered) masked region becomes visible on the new layer.
        var out = matched
        for i in 0..<(roi.width * roi.height) {
            out.pixels[i * 4 + 3] = alpha.values[i] * crop.pixels[i * 4 + 3] / 255
        }
        return InpaintResult(image: out, origin: SIMD2(roi.x, roi.y), cost: result.cost)
    }

    // MARK: Expand / outpaint

    public struct Margins: Equatable, Sendable {
        public var top: Int, right: Int, bottom: Int, left: Int

        public init(top: Int, right: Int, bottom: Int, left: Int) {
            self.top = max(0, top); self.right = max(0, right); self.bottom = max(0, bottom); self.left = max(0, left)
        }

        /// Symmetric margins growing the image by `factor` (1.5 = 50 % larger).
        public static func scaled(width: Int, height: Int, factor: Double) -> Margins {
            let dx = Int((Double(width) * (factor - 1) / 2).rounded()), dy = Int((Double(height) * (factor - 1) / 2).rounded())
            return Margins(top: dy, right: dx, bottom: dy, left: dx)
        }

        public var isEmpty: Bool { top + right + bottom + left == 0 }
    }

    public static func outpaintInstruction(prompt: String) -> String {
        let base = "You are extending the FIRST image onto a larger canvas. The SECOND image "
            + "is a mask: white marks the NEW border area you must paint; black marks the "
            + "original photo, which must remain byte-for-byte identical. Continue the "
            + "scene naturally outward — matching perspective, lighting, color and texture "
            + "at the seam. Do not add a frame, border or vignette, and do not alter, "
            + "shift or resize the original (black) region."
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? base : base + " The newly revealed area should depict: \(p)."
    }

    /// Extends `image` by `margins`. Returns the full expanded image.
    public static func expand(_ image: RGBAImage, margins m: Margins, prompt: String, seed: Int? = nil,
                              model: ImageModel) async throws -> AIImageResult {
        let w = image.width + m.left + m.right, h = image.height + m.top + m.bottom
        var canvas = RGBAImage(width: w, height: h, fill: SIMD4(128, 128, 128, 255))
        canvas.paste(image, x: m.left, y: m.top)
        var mask = GrayImage(width: w, height: h, fill: 255)
        mask.paste(GrayImage(width: image.width, height: image.height, fill: 0), x: m.left, y: m.top)
        let seam = Imaging.featherMask(mask, erode: 0, blur: 4)

        var result = try await model.generate(prompt: outpaintInstruction(prompt: prompt), images: [canvas, mask.rgba], seed: seed)
        let aligned = result.image.resized(width: w, height: h)
        let matched = Imaging.colorMatch(aligned, to: canvas, trusted: mask.inverted)
        var composited = Imaging.blendMasked(canvas, matched, alpha: seam)
        var hardInset = GrayImage(width: w, height: h, fill: 0)
        hardInset.paste(GrayImage(width: image.width, height: image.height, fill: 255), x: m.left, y: m.top)
        composited = Imaging.blendMasked(composited, canvas, alpha: Imaging.featherMask(hardInset, erode: 4, blur: 2))
        result.image = composited
        return result
    }
}
