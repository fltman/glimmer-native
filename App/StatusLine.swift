import GlimmerCore
import SwiftUI

/// A state said in the window (the-apps/SIBLINGS.md, "Tillstånd i fönstret: fel, varning, upplysning").
///
/// The symbol carries the kind and its colour; the text stays in the label colour, so it reads at full
/// contrast in light and dark. VoiceOver hears the kind as a word first ("Error: …"), since it hears neither
/// the shape nor the colour. Every state in a view goes through this type or `StatusSymbol`: no view picks a
/// red, an orange or a triangle for itself (scripts/check-status.py holds that).
struct StatusLine: View {
    let kind: StatusKind
    let text: Text

    init(_ kind: StatusKind, _ key: LocalizedStringKey) { self.kind = kind; text = Text(key) }
    /// For a text that is already in the person's language (an error's own words, a file's name).
    init(_ kind: StatusKind, verbatim: String) { self.kind = kind; text = Text(verbatim: verbatim) }

    var body: some View {
        Label { text } icon: { StatusSymbol(kind).accessibilityHidden(true) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(kind.spoken(text))
    }
}

/// The symbol of a state alone, in its colour (a row's status in a list). Work under way is a spinner.
struct StatusSymbol: View {
    let kind: StatusKind
    @Environment(\.colorScheme) private var scheme

    init(_ kind: StatusKind) { self.kind = kind }

    var body: some View {
        if let symbol = kind.symbol {
            Image(systemName: symbol).foregroundStyle(kind.color(scheme))
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

extension StatusKind {
    /// The symbol's colour for the surface it stands on.
    func color(_ scheme: ColorScheme) -> Color {
        let c = color(onDark: scheme == .dark)
        return Color(red: c.red, green: c.green, blue: c.blue)
    }

    /// The word VoiceOver says for the kind, alone (a symbol in a list).
    var spokenName: Text {
        switch self {
        case .error: Text("Error")
        case .warning: Text("Warning")
        case .notice: Text("Note")
        case .success: Text("Done")
        case .working: Text("Running")
        }
    }

    /// "Error: <text>" for VoiceOver; a notice and work under way are said as they are.
    func spoken(_ text: Text) -> Text {
        switch self {
        case .error: Text("Error:") + Text(verbatim: " ") + text
        case .warning: Text("Warning:") + Text(verbatim: " ") + text
        case .success: Text("Done:") + Text(verbatim: " ") + text
        case .notice, .working: text
        }
    }
}
