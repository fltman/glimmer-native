import GlimmerCore
import SwiftUI

/// The document's vector paths (pen tool output), with fill / stroke / selection actions.
struct PathsPanel: View {
    @Bindable var session: EditorSession
    @State private var renaming: UUID?
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            if let shape = session.activeLayer, let vector = shape.vectorMask {
                Button {
                    session.activePathID = session.activePathID == vector.id ? nil : vector.id
                    if session.activePathID != nil { session.tool = .pen }
                } label: {
                    HStack {
                        Image(systemName: "square.on.circle").foregroundStyle(.secondary)
                        Text("\(shape.name) Shape Path")
                        Spacer()
                        if session.activePathID == vector.id { Image(systemName: "pencil").foregroundStyle(.tint) }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(session.activePathID == vector.id ? Color.accentColor.opacity(0.15) : .clear)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Edit the shape with the Pen tool")
                Divider()
            }
            if session.state.paths.isEmpty {
                ContentUnavailableView("No Paths", systemImage: "pencil.tip.crop.circle",
                                       description: Text("Draw with the Pen tool (P) to create a path."))
            } else {
                List(selection: Binding(get: { session.activePathID }, set: { session.activePathID = $0 })) {
                    ForEach(session.state.paths) { path in
                        row(path).tag(path.id)
                    }
                }
                .listStyle(.sidebar)
            }
            Divider()
            HStack(spacing: 12) {
                let id = session.activePathID
                Button("Fill", systemImage: "paintbrush.fill") { id.map(session.fillPath) }
                    .help("Fill the path with the foreground colour on the active layer")
                Button("Stroke", systemImage: "paintbrush.pointed") { id.map(session.strokePath) }
                    .help("Stroke the path with the current brush")
                Button("Selection", systemImage: "lasso") { id.map(session.makeSelection(fromPath:)) }
                    .help("Load the path as a selection")
                Button("Type on Path", systemImage: "character.cursor.ibeam") { id.map(session.addTextOnPath) }
                    .help("Add text that follows the path")
                Spacer()
                Button("Delete", systemImage: "trash") { id.map(session.deletePath) }
                    .help("Delete the path")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(session.activePathID == nil)
            .padding(8)
        }
    }

    @ViewBuilder private func row(_ path: VectorPath) -> some View {
        HStack {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .foregroundStyle(.secondary)
            if renaming == path.id {
                TextField("Name", text: $draft)
                    .onSubmit {
                        session.renamePath(path.id, to: draft)
                        renaming = nil
                    }
            } else {
                Text(path.name)
                    .onTapGesture(count: 2) {
                        draft = path.name
                        renaming = path.id
                    }
            }
            Spacer()
            Text("\(path.subpaths.reduce(0) { $0 + $1.anchors.count }) pts")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
