import GlimmerCore
import SwiftUI

struct FilterDialogItem: Identifiable {
    let settings: FilterSettings
    var id: String { settings.kind.rawValue }
}

/// Channels of the composite, as in the web app: the eye shows or hides a channel,
/// clicking a row shows it alone (one colour channel appears in grey), and any
/// channel can be loaded as a selection.
struct ChannelsPanel: View {
    @Bindable var session: EditorSession

    private struct Row: Identifiable {
        let id: Int
        let name: String
        let color: Color
        /// Bits of `channelMask` this row stands for.
        let bits: Int
    }

    private let rows = [
        Row(id: 0, name: "RGB", color: .primary, bits: 7),
        Row(id: 1, name: "Red", color: .red, bits: 1),
        Row(id: 2, name: "Green", color: .green, bits: 2),
        Row(id: 3, name: "Blue", color: .blue, bits: 4),
        Row(id: 4, name: "Alpha", color: .white, bits: 8),
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                ForEach(rows) { row in
                    let isOn = session.channelMask & row.bits == row.bits
                    HStack(spacing: 8) {
                        Button {
                            session.channelMask = isOn ? session.channelMask & ~row.bits : session.channelMask | row.bits
                        } label: {
                            Image(systemName: isOn ? "eye" : "eye.slash")
                                .foregroundStyle(isOn ? .primary : .tertiary)
                                .frame(width: 22)
                        }
                        .buttonStyle(.borderless)
                        .help(isOn ? "Hide this channel" : "Show this channel")
                        .accessibilityLabel(Text(isOn ? "Hide \(row.name)" : "Show \(row.name)"))
                        Image(systemName: row.id == 0 ? "circle.grid.cross" : "circle.fill")
                            .foregroundStyle(row.color)
                            .accessibilityHidden(true)  // the name says which channel
                        Text(LocalizedStringKey(row.name))
                        Spacer()
                        Button {
                            session.loadChannelAsSelection(row.id)
                        } label: {
                            Label(row.id == 0 ? "Load luminosity as selection" : "Load \(row.name) as selection",
                                  systemImage: "selection.pin.in.out")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help(row.id == 0 ? "Load luminosity as selection" : "Load this channel as selection")
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background {
                        if isOn { RoundedRectangle(cornerRadius: 6).fill(Theme.raised) }
                    }
                    .contentShape(.rect)
                    .onTapGesture {
                        // Show this channel alone; RGB is the normal view.
                        session.channelMask = row.id == 0 ? 15 : row.bits
                    }
                }
            }
            .padding(8)
            if session.channelMask != 15 {
                Button("Show All Channels") { session.channelMask = 15 }
                    .controlSize(.small)
                    .padding(.bottom, 6)
            }
            Text("Click a channel to see it alone, in grey. The eyes combine channels. Channel views don't change the image.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
            Spacer(minLength: 0)
        }
    }
}
