import CoreText
import Foundation

/// A stretch of a text layer styled differently from the rest of it: a word in bold, another
/// colour or size. `location` and `length` count UTF-16 code units of `TextLayer.string` (the
/// offsets of NSString and NSTextView). A nil field keeps the layer's own value.
public struct TextStyleRun: Codable, Hashable, Sendable {
    public var location: Int
    public var length: Int
    public var fontName: String?
    public var size: Double?
    public var color: SRGBColor?

    public init(location: Int, length: Int, fontName: String? = nil, size: Double? = nil, color: SRGBColor? = nil) {
        self.location = location
        self.length = length
        self.fontName = fontName
        self.size = size
        self.color = color
    }

    public var range: NSRange { NSRange(location: location, length: length) }
    var isPlain: Bool { fontName == nil && size == nil && color == nil }
}

/// The font, size and colour a character of a text layer is drawn with.
public struct TextStyle: Hashable, Sendable {
    public var fontName: String
    public var size: Double
    public var color: SRGBColor

    public init(fontName: String, size: Double, color: SRGBColor) {
        self.fontName = fontName
        self.size = size
        self.color = color
    }
}

extension TextLayer {
    /// The layer's own style, used wherever no run says otherwise.
    public var baseStyle: TextStyle { TextStyle(fontName: fontName, size: size, color: color) }

    /// Whether some characters are styled differently from the layer.
    public var hasStyledRuns: Bool { !(styles ?? []).isEmpty }

    private var unitCount: Int { (string as NSString).length }

    private struct Override: Hashable {
        var fontName: String?
        var size: Double?
        var color: SRGBColor?
    }

    private func overridesPerUnit() -> [Override] {
        var units = [Override](repeating: Override(), count: unitCount)
        for run in styles ?? [] {
            let lo = max(0, run.location), hi = min(units.count, run.location + run.length)
            guard lo < hi else { continue }
            for i in lo..<hi {
                if let f = run.fontName { units[i].fontName = f }
                if let s = run.size { units[i].size = s }
                if let c = run.color { units[i].color = c }
            }
        }
        return units
    }

    /// Collapses per-unit overrides into runs, leaving out what equals the layer's own style.
    private mutating func setOverrides(_ units: [Override]) {
        var runs: [TextStyleRun] = []
        var i = 0
        while i < units.count {
            var o = units[i]
            if o.fontName == fontName { o.fontName = nil }
            if o.size == size { o.size = nil }
            if o.color == color { o.color = nil }
            var j = i + 1
            while j < units.count {
                var next = units[j]
                if next.fontName == fontName { next.fontName = nil }
                if next.size == size { next.size = nil }
                if next.color == color { next.color = nil }
                guard next == o else { break }
                j += 1
            }
            let run = TextStyleRun(location: i, length: j - i, fontName: o.fontName, size: o.size, color: o.color)
            if !run.isPlain { runs.append(run) }
            i = j
        }
        styles = runs.isEmpty ? nil : runs
    }

    /// The style of the character at a UTF-16 offset (the last character at the end of the text).
    public func style(at offset: Int) -> TextStyle {
        var s = baseStyle
        let n = unitCount
        guard n > 0 else { return s }
        let i = min(max(offset, 0), n - 1)
        for run in styles ?? [] where i >= run.location && i < run.location + run.length {
            if let f = run.fontName { s.fontName = f }
            if let v = run.size { s.size = v }
            if let c = run.color { s.color = c }
        }
        return s
    }

    /// The whole text cut into stretches of one style each, in order.
    public func resolvedRuns() -> [(range: NSRange, style: TextStyle)] {
        let units = overridesPerUnit()
        var out: [(range: NSRange, style: TextStyle)] = []
        var i = 0
        while i < units.count {
            var j = i + 1
            while j < units.count, units[j] == units[i] { j += 1 }
            let o = units[i]
            out.append((NSRange(location: i, length: j - i),
                        TextStyle(fontName: o.fontName ?? fontName, size: o.size ?? size, color: o.color ?? color)))
            i = j
        }
        return out
    }

    /// Restyles part of the text; nil arguments leave that property as it is.
    public mutating func setStyle(in range: NSRange, fontName: String? = nil, size: Double? = nil, color: SRGBColor? = nil) {
        var units = overridesPerUnit()
        let lo = max(0, range.location), hi = min(units.count, range.location + range.length)
        guard lo < hi else { return }
        for i in lo..<hi {
            if let fontName { units[i].fontName = fontName }
            if let size { units[i].size = max(size, 1) }
            if let color { units[i].color = color }
        }
        setOverrides(units)
    }

    /// Sets the text and the style of every stretch at once (what the text editor holds when
    /// it closes). Only what differs from the layer's own style is kept.
    public mutating func setStyledText(_ newString: String, runs: [(range: NSRange, style: TextStyle)]) {
        string = newString
        var units = [Override](repeating: Override(), count: unitCount)
        for run in runs {
            let lo = max(0, run.range.location), hi = min(units.count, run.range.location + run.range.length)
            guard lo < hi else { continue }
            for i in lo..<hi { units[i] = Override(fontName: run.style.fontName, size: run.style.size, color: run.style.color) }
        }
        setOverrides(units)
    }

    /// After a change to the whole layer: drops the per-word values of the properties that
    /// changed, so the change shows everywhere (as in Photoshop with the layer selected).
    public mutating func dropStyles(changedFrom old: TextLayer) {
        guard var runs = styles else { return }
        for i in runs.indices {
            if fontName != old.fontName { runs[i].fontName = nil }
            if size != old.size { runs[i].size = nil }
            if color != old.color { runs[i].color = nil }
        }
        styles = runs
        setOverrides(overridesPerUnit())
    }

    /// Keeps the runs over the same characters after the text changed from `old` to `string`
    /// without the editor (an agent, a script): characters that stayed keep their style, and
    /// inserted text takes the style of the character before it.
    public mutating func carryStyles(from old: String) {
        guard hasStyledRuns else { return }
        let a = Array(old.utf16), b = Array(string.utf16)
        var oldLayer = self
        oldLayer.string = old
        let oldUnits = oldLayer.overridesPerUnit()
        let diff = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var units = [Override]()
        units.reserveCapacity(b.count)
        var i = 0
        for j in 0..<b.count {
            while i < a.count, removed.contains(i) { i += 1 }
            if inserted.contains(j) {
                units.append(units.last ?? (i < oldUnits.count ? oldUnits[i] : Override()))
            } else {
                units.append(i < oldUnits.count ? oldUnits[i] : Override())
                i += 1
            }
        }
        setOverrides(units)
    }

    /// The largest font size in the text.
    public var largestSize: Double { (styles ?? []).compactMap(\.size).reduce(size, max) }

    /// Attributes of a stretch drawn in `style`.
    func attributes(for style: TextStyle) -> [NSAttributedString.Key: Any] {
        [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(style.fontName as CFString, style.size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(srgbRed: style.color.r, green: style.color.g, blue: style.color.b, alpha: 1),
            NSAttributedString.Key(kCTKernAttributeName as String): tracking / 1000 * style.size,
        ]
    }
}
