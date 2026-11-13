import SwiftUI

/// Every undoable step since the document was opened. Clicking a step undoes
/// or redoes to it; later steps stay redoable until the next edit.
struct HistoryPanel: View {
    let session: EditorSession

    var body: some View {
        let document = session.document
        ScrollViewReader { proxy in
            List {
                row("Open", systemImage: "doc", index: 0, current: document.historyIndex == 0, future: false)
                ForEach(Array(document.history.enumerated()), id: \.offset) { i, name in
                    row(name, systemImage: "arrow.uturn.backward.circle", index: i + 1,
                        current: document.historyIndex == i + 1, future: i + 1 > document.historyIndex)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onChange(of: document.history.count) { proxy.scrollTo(document.history.count, anchor: .bottom) }
        }
        Text(document.stepsOnDisk > 0
             ? "Keeps the last \(GlimmerDocument.historyLimit) steps; \(document.stepsOnDisk) older ones are on disk. Change it in Settings › Performance."
             : "Keeps the last \(GlimmerDocument.historyLimit) steps. Change it in Settings › Performance.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(8)
    }

    private func row(_ name: String, systemImage: String, index: Int, current: Bool, future: Bool) -> some View {
        Button {
            session.commitLiveEdit()
            session.document.jumpToHistory(index, undoManager: session.undoManager)
        } label: {
            Label(LocalizedStringKey(name), systemImage: systemImage)
                .foregroundStyle(future ? .tertiary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(current ? Color.accentColor.opacity(0.2) : Color.clear)
        .id(index)
        .accessibilityAddTraits(current ? .isSelected : [])
        .accessibilityHint(future ? "Redo to this step" : "Undo to this step")
    }
}
