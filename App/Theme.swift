import SwiftUI

/// Glimmer's look, shared with the web app: near-black surfaces, soft borders
/// and an indigo accent.
enum Theme {
    static let background = Color(red: 0x0c / 255, green: 0x0d / 255, blue: 0x11 / 255)
    static let panel = Color(red: 0x16 / 255, green: 0x17 / 255, blue: 0x1c / 255)
    static let raised = Color(red: 0x1f / 255, green: 0x20 / 255, blue: 0x27 / 255)
    static let edge = Color(red: 0x2c / 255, green: 0x2e / 255, blue: 0x37 / 255)
    static let ink = Color(red: 0xe8 / 255, green: 0xe9 / 255, blue: 0xef / 255)
    static let muted = Color(red: 0x96 / 255, green: 0x9a / 255, blue: 0xa7 / 255)
    static let accent = Color(red: 0x6d / 255, green: 0x7d / 255, blue: 0xff / 255)
    /// The accent for filled surfaces with white text (prominent buttons, your chat
    /// messages): 4.8 : 1 with white, where `accent` gives only 3.5 : 1. `accent` stays for
    /// text, icons and borders on dark surfaces (5.1 : 1 on `panel`).
    static let accentFill = Color(red: 0x55 / 255, green: 0x63 / 255, blue: 0xe8 / 255)
    /// Outline of input fields: 3.1 : 1 against `panel`, where `edge` gives 1.3 : 1.
    static let fieldEdge = Color(red: 0x96 / 255, green: 0x9a / 255, blue: 0xa7 / 255).opacity(0.6)
    /// The canvas surround, as sRGB components.
    static let backgroundRGB: (Double, Double, Double) = (0x0c / 255.0, 0x0d / 255.0, 0x11 / 255.0)
}

extension View {
    /// A floating chrome surface: solid panel colour, hairline border, soft shadow.
    func panelSurface(cornerRadius: CGFloat = 12) -> some View {
        background(Theme.panel.opacity(0.96), in: .rect(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Theme.edge, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }
}

/// The small labelled buttons along the top of the canvas (AI, Tools, Layers, Export).
struct ChromeChip: View {
    let title: LocalizedStringKey
    let systemImage: String
    var isOn = false
    var showsTitle = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.callout.weight(.medium)).imageScale(.small)
                if showsTitle { Text(title).font(.callout) }
            }
            .foregroundStyle(isOn ? Theme.ink : Theme.muted)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)  // grows with larger text
            .background(isOn ? Theme.accent.opacity(0.35) : Theme.panel.opacity(0.96), in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isOn ? Theme.accent : Theme.edge, lineWidth: 1))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
