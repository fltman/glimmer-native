import GlimmerCore
import SwiftUI

/// What came through when a Photoshop file was opened, and what did not. Shown when the file
/// opens and from File › Import Report…: an import never happens silently.
struct ImportReportSheet: View {
    let session: EditorSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let report = session.importReport
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Report").font(.headline)
            if let report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(report.lines.enumerated()), id: \.offset) { index, line in
                            Text(verbatim: line)
                                .font(index == 0 ? .body.weight(.medium) : .callout)
                                .foregroundStyle(index == 0 ? .primary : .secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 320)
                Text("The Photoshop file itself is not changed. This is a new Glimmer document; you can read the report again under File › Import Report… while the window is open.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
