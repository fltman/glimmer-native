import GlimmerCore
import GlimmerTools
import SwiftUI

/// ⌘K: fuzzy search over every command, tool, filter, adjustment and preset.
/// Text that reads like a request goes to the assistant instead.
struct CommandPalette: View {
    let session: EditorSession
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private enum Row: Identifiable {
        case item(PaletteItem)
        case ask(String)
        var id: String {
            switch self {
            case .item(let i): i.id
            case .ask: "ask"
            }
        }
    }

    static let allItems: [PaletteItem] = {
        let registry = CommandRegistry.standard
        var items = registry.descriptors.filter { !$0.isSystemProvided && $0.id != .commandPalette }.map { d in
            PaletteItem(id: d.id.rawValue, title: d.title, subtitle: d.id.adjustmentKind != nil ? "Adjustment"
                            : d.id.filterKind.map { "Filter › \($0.group)" } ?? d.category.rawValue.capitalized,
                        keywords: d.keywords, action: .command(d.id))
        }
        items += CanvasNSView.availableTools.map { t in
            PaletteItem(id: "tool.\(t.rawValue)", title: t.title, subtitle: "Tool" + (t.shortcutKey.map { " (\(String($0).uppercased()))" } ?? ""),
                        keywords: ["tool"], action: .tool(t.rawValue))
        }
        items += Preset.all.map { p in
            PaletteItem(id: "preset.\(p.id)", title: p.name, subtitle: "Preset", keywords: ["look", "preset", "style"], action: .preset(p.id))
        }
        return items
    }()

    private var rows: [Row] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let results = CommandSearch.search(q, in: Self.allItems, limit: q.isEmpty ? 0 : 9)
        var rows = results.map { Row.item($0.item) }
        guard !q.isEmpty else { return rows }
        if CommandSearch.looksLikeAssistantRequest(q, bestScore: results.first?.score) {
            rows.insert(.ask(q), at: 0)
        } else {
            rows.append(.ask(q))
        }
        return rows
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.secondary)
                TextField("Search commands, or ask for an edit…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { run(rows, index: selection) }
                    .onKeyPress(.downArrow) { selection = min(selection + 1, max(rows.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                    .onKeyPress(.escape) { session.isPaletteOpen = false; return .handled }
                    .onChange(of: query) { selection = 0 }
            }
            .padding(14)
            if !rows.isEmpty {
                Divider()
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            rowView(row, selected: index == selection)
                                .contentShape(.rect)
                                .onTapGesture { run(rows, index: index) }
                        }
                    }
                    .padding(6)
                }
                .frame(height: min(CGFloat(rows.count) * 34 + 12, 360))
            } else {
                Text("Try “blur”, “curves”, “brush”, or describe an edit: “make it look like film”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 560)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .onAppear { focused = true }
    }

    @ViewBuilder private func rowView(_ row: Row, selected: Bool) -> some View {
        HStack(spacing: 10) {
            switch row {
            case .item(let item):
                Image(systemName: symbol(item)).frame(width: 18).foregroundStyle(.secondary)
                Text(LocalizedStringKey(item.title))
                Spacer()
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                if case .command(let id) = item.action, let s = CommandRegistry.standard.descriptor(for: id)?.shortcut {
                    Text(s.display).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            case .ask(let q):
                Image(systemName: "sparkles").frame(width: 18).foregroundStyle(.tint)
                Text("Ask the assistant: “\(q)”").lineLimit(1)
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(selected ? Color.accentColor.opacity(0.2) : .clear, in: .rect(cornerRadius: 8))
    }

    private func symbol(_ item: PaletteItem) -> String {
        switch item.action {
        case .tool(let raw): ToolID(rawValue: raw)?.symbolName ?? "hammer"
        case .preset: "camera.filters"
        case .command(let id):
            if id.filterKind != nil { "camera.aperture" } else if id.adjustmentKind != nil { "slider.horizontal.3" } else { "command" }
        }
    }

    private func run(_ rows: [Row], index: Int) {
        guard rows.indices.contains(index) else { return }
        session.isPaletteOpen = false
        switch rows[index] {
        case .ask(let q):
            session.showLayersPanel = true
            session.inspectorTab = .ai
            session.ai.ask(q)
        case .item(let item):
            if !session.runPaletteItem(item) { NSSound.beep() }
        }
    }
}

extension EditorSession {
    /// Runs a palette entry (command, tool or preset). Returns false when it isn't available now.
    @discardableResult
    func runPaletteItem(_ item: PaletteItem) -> Bool {
        switch item.action {
        case .command(let id):
            guard canPerform(id) else { return false }
            perform(id)
        case .tool(let raw):
            guard let t = ToolID(rawValue: raw) else { return false }
            tool = t
        case .preset(let id):
            guard let p = Preset.all.first(where: { $0.id == id }) else { return false }
            ai.applyPreset(p)
        }
        return true
    }
}

/// The omnibar: a quiet pill at the bottom of the canvas that opens the palette.
struct Omnibar: View {
    let session: EditorSession

    var body: some View {
        Button {
            session.isPaletteOpen = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass")
                Text("Search or ask…")
                Text("⌘K").font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .help("Search commands or ask the assistant (⌘K)")
    }
}

extension KeyShortcut {
    var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + String(key).uppercased()
    }
}
