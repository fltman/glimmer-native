import GlimmerCore
import SwiftUI

/// File › Linked Files Waiting…: the edits of files from Flimmer or Jämmer that are kept in the link journal and
/// are not open in a window now (closed with Keep for Later, or left by a launch that could not open them).
/// An entry nobody can find would be lost work; here each one can be opened again, or moved to the Trash.
struct LinkedWaitingView: View {
    let close: () -> Void
    @State private var entries: [LinkJournal.Entry] = []
    @State private var broken: [String] = []
    @State private var asked: LinkJournal.Entry?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Linked Files Waiting").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text("Edits of files from another app that are not saved back yet. Open one to go on with it and save it back.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if entries.isEmpty {
                Text("Nothing is waiting.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ForEach(entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: entry.record.fileName).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                            Text(Self.detail(entry)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .layoutPriority(1)
                        Spacer(minLength: 8)
                        // The buttons are never cut short; the line under the name wraps instead.
                        Button("Open") {
                            if DocumentOpener.shared.open(entry) { close() }
                            else { problem = String(localized: "Glimmer couldn't read these edits. They are left where they are.") }
                        }
                        .fixedSize()
                        Button("Discard…") { asked = entry }
                            .fixedSize()
                    }
                    .accessibilityElement(children: .contain)
                    Divider()
                }
            }
            if !broken.isEmpty {
                StatusLine(.error, "\(broken.count) kept edit(s) can't be read. They are left in Glimmer's folder and are not removed.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let problem { StatusLine(.error, verbatim: problem).font(.callout) }
            HStack { Spacer(); Button("Done", action: close).keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: load)
        .confirmationDialog(Text("Move the edits of \(asked?.record.fileName ?? "") to the Trash?"),
                            isPresented: Binding(get: { asked != nil }, set: { if !$0 { asked = nil } }), presenting: asked) { entry in
            Button("Move to Trash", role: .destructive) {
                if !LinkJournal.shared.discard(entry) { problem = String(localized: "Glimmer couldn't move the edits to the Trash, so they are kept.") }
                load()
            }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            // What is lost, and that the file itself is not touched.
            let steps = entry.record.unreturnedSteps ?? 1
            Text(steps == 1
                 ? "The step you made in Glimmer is not saved back to \(entry.record.link.requester) and will no longer be here. \(entry.record.fileName) itself stays as it is. The layered copy goes to the Trash, where you can still get it."
                 : "The \(steps) steps you made in Glimmer are not saved back to \(entry.record.link.requester) and will no longer be here. \(entry.record.fileName) itself stays as it is. The layered copy goes to the Trash, where you can still get it.")
        }
    }

    private func load() {
        entries = DocumentOpener.shared.waitingEntries()
        broken = LinkJournal.shared.broken
    }

    /// "For Flimmer · edits not saved back · 2 hours ago"
    static func detail(_ entry: LinkJournal.Entry) -> String {
        let age = RelativeDateTimeFormatter().localizedString(for: entry.record.writtenAt, relativeTo: Date())
        let size = ByteCountFormatter.string(fromByteCount: Int64(LinkJournalWriter.bytes(of: entry.folder)), countStyle: .file)
        let steps = entry.record.unreturnedSteps ?? 1
        let state = !entry.record.unreturned ? String(localized: "saved back")
            : steps == 1 ? String(localized: "1 step not saved back") : String(localized: "\(steps) steps not saved back")
        return String(localized: "For \(entry.record.link.requester) · \(state) · \(age) · \(size)")
    }
}
