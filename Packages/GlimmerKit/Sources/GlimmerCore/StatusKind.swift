import Foundation

/// A state said in the window: an error, a warning, a notice, a success, or work under way
/// (the-apps/SIBLINGS.md, "Tillstånd i fönstret: fel, varning, upplysning").
///
/// They must be told apart without colour, in light and dark, and by someone who cannot tell red from green.
/// So each kind has one symbol, used for nothing else in the whole app, and a prefix that VoiceOver speaks;
/// the colour sits on the symbol and the text stays in the label colour. This one type gives all three, so that
/// no view picks a colour or a symbol for a state by itself.
///
/// Why the shape and the word, and not the colour, carry it: the error and warning colours below differ in
/// luminance by 1.56 : 1 on a dark surface and 1.01 : 1 on a light one. Seen without hue they are the same.
public enum StatusKind: String, CaseIterable, Sendable {
    /// Something could not be done. The text says what.
    case error
    /// Something was done, or stands, with a consequence the person may need to act on. The text says the consequence.
    case warning
    /// Something worth knowing; nothing to act on.
    case notice
    case success
    /// Work under way: shown with a progress indicator and the word, not with a symbol.
    case working

    /// The SF Symbol; nil for `working`.
    public var symbol: String? {
        switch self {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .notice: "info.circle"
        case .success: "checkmark.circle.fill"
        case .working: nil
        }
    }

    /// What VoiceOver says before the text ("Error: …"); a catalogue key. A notice and work under way need no prefix.
    public var prefix: String? {
        switch self {
        case .error: "Error:"
        case .warning: "Warning:"
        case .success: "Done:"
        case .notice, .working: nil
        }
    }

    /// The symbol's colour as sRGB (0…1) on a dark surface (Glimmer's own windows, and the system's dark ones)
    /// and on a light one. At least 3 : 1 against every surface it stands on (`StatusKindTests`).
    public func color(onDark: Bool) -> (red: Double, green: Double, blue: Double) {
        let hex: UInt32 = switch (self, onDark) {
        case (.error, true): 0xff6b6b
        case (.warning, true): 0xffb340
        case (.notice, true), (.working, true): 0x969aa7
        case (.success, true): 0x4cd787
        case (.error, false): 0xc22a26
        case (.warning, false): 0x9a5600
        case (.notice, false), (.working, false): 0x5f636f
        case (.success, false): 0x1a733d
        }
        return (Double((hex >> 16) & 0xff) / 255, Double((hex >> 8) & 0xff) / 255, Double(hex & 0xff) / 255)
    }

    /// WCAG relative luminance of an sRGB colour.
    public static func luminance(_ c: (red: Double, green: Double, blue: Double)) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
    }

    /// WCAG contrast ratio of two sRGB colours.
    public static func contrast(_ a: (red: Double, green: Double, blue: Double), _ b: (red: Double, green: Double, blue: Double)) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
