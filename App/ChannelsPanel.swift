import GlimmerCore
import SwiftUI

struct FilterDialogItem: Identifiable {
    let settings: FilterSettings
    var id: String { settings.kind.rawValue }
}

/// RGB channels of the composite: view one channel in grey, or load it as a selection.
struct ChannelsPanel: View {
    @Bindable var session: EditorSession

    private let channels: [(Int, String, Color)] = [(0, "RGB", .primary), (1, "Red", .red), (2, "Green", .green), (3, "Blue", .blue)]

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $session.viewChannel) {
                ForEach(channels, id: \.0) { index, name, color in
                    HStack {
                        Image(systemName: index == 0 ? "circle.grid.cross" : "circle.fill")
                            .foregroundStyle(color)
                        Text(name)
                        Spacer()
                        Button {
                            session.loadChannelAsSelection(index)
                        } label: {
                            Image(systemName: "selection.pin.in.out")
                        }
                        .buttonStyle(.borderless)
                        .help("Load \(name == "RGB" ? "luminosity" : name.lowercased() + " channel") as selection")
                    }
                    .tag(index)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            Text("Click a channel to view it in grey. Channel views don't change the image.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }
}
