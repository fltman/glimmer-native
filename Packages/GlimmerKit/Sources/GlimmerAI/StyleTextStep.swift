import Foundation
import GlimmerCore

extension SRGBColor {
    /// `#RRGGBB`, the reverse of `parseHexColor`.
    public var hexString: String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}

/// The `style_text` step on a text layer, apart from finding the layer: which characters,
/// what style, and what to report.
public enum StyleTextStep {
    public struct Refusal: Error, LocalizedError, Equatable {
        public let reason: String
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Styles `text` as the step says and returns the step's `info`:
    /// `{"matches": n, "ranges": [{"from", "length"}]}` in characters (grapheme clusters).
    public static func apply(_ step: AgentStep, to text: inout TextLayer) throws -> [String: Any] {
        let fontName = step.string("fontName")?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let bold = step.params["bold"]?.bool
        let size = step.number("size")
        let colorText = step.string("color")
        let color = parseHexColor(colorText)
        if colorText != nil, color == nil { throw Refusal(reason: "bad_color", message: "color must be #RRGGBB.") }
        if let size, !(size >= 1 && size <= 10_000) { throw Refusal(reason: "bad_size", message: "size must be 1–10000 pixels.") }
        guard fontName != nil || bold != nil || size != nil || color != nil else {
            throw Refusal(reason: "nothing_to_style", message: "Give fontName, bold, size or color.")
        }
        if let fontName, !TextLayer.fontExists(fontName) {
            throw Refusal(reason: "unknown_font", message: "No font named “\(fontName)” is installed (use its PostScript name).")
        }

        let ranges: [NSRange]
        if let match = step.string("match"), !match.isEmpty {
            let all = (step.string("occurrence") ?? "all") != "first"
            ranges = text.ranges(of: match, all: all)
            guard !ranges.isEmpty else { throw Refusal(reason: "no_match", message: "“\(match)” isn't in the text.") }
        } else if let from = step.number("from") {
            let length = step.number("length") ?? 1
            guard from == from.rounded(), length == length.rounded(),
                  let r = text.utf16Range(characterFrom: Int(from), length: Int(length)) else {
                throw Refusal(reason: "bad_range",
                              message: "from/length is outside the text, which has \(text.string.count) characters (grapheme clusters).")
            }
            ranges = [r]
        } else {
            // No words named: the whole text, as when nothing is selected.
            guard let r = text.utf16Range(characterFrom: 0, length: text.string.count) else {
                throw Refusal(reason: "bad_range", message: "The text is empty.")
            }
            ranges = [r]
        }

        var styled = text
        for r in ranges {
            if let fontName { styled.setStyle(in: r, fontName: fontName) }
            if let bold, !styled.setBold(bold, in: r) {
                throw Refusal(reason: "unknown_font", message: "The font has no \(bold ? "bold" : "regular") member.")
            }
            styled.setStyle(in: r, size: size, color: color)
        }
        text = styled
        return ["matches": ranges.count,
                "ranges": ranges.map { r -> [String: Any] in
                    let c = text.characterRange(of: r)
                    return ["from": c.from, "length": c.length]
                }]
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
