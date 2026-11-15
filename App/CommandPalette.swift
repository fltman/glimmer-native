import GlimmerCore
import GlimmerTools
import SwiftUI

/// One line in the command palette or under the omnibar.
enum PaletteRow: Identifiable {
    case item(PaletteItem)
    case ask(String)

    var id: String {
        switch self {
        case .item(let i): i.id
        case .ask: "ask"
        }
    }
}

/// What the palette and the omnibar share: the searchable items, the rows for
/// a query, and running a row.
enum Palette {
    /// Commands the menus already have elsewhere (or don't need) but the palette should find.
    static let paletteOnly: Set<CommandID> = [.newDocument, .openDocument, .showLayers, .showPaths, .showChannels, .showHistory]

    @MainActor static let allItems: [PaletteItem] = {
        let registry = CommandRegistry.standard
        var items = registry.descriptors.filter { (!$0.isSystemProvided || Palette.paletteOnly.contains($0.id)) && $0.id != .commandPalette }.map { d in
            PaletteItem(id: d.id.rawValue, title: d.title, subtitle: d.id.adjustmentKind != nil ? "Adjustment"
                            : d.id.filterKind.map { "Filter › \($0.group)" } ?? d.category.rawValue.capitalized,
                        keywords: d.keywords + localized(d.title), action: .command(d.id))
        }
        items += CanvasNSView.availableTools.map { t in
            PaletteItem(id: "tool.\(t.rawValue)", title: t.title, subtitle: "Tool" + (t.shortcutKey.map { " (\(String($0).uppercased()))" } ?? ""),
                        keywords: ["tool"] + localized(t.title), action: .tool(t.rawValue))
        }
        items += Preset.all.map { p in
            PaletteItem(id: "preset.\(p.id)", title: p.name, subtitle: "Preset",
                        keywords: ["look", "preset", "style"] + localized(p.name), action: .preset(p.id))
        }
        return items
    }()

    static let recentsKey = "palette.recents"

    /// The title in the user's language, when it differs, so typing Swedish
    /// ("webben", "himmel") finds the command too.
    static func localized(_ title: String) -> [String] {
        let local = String(localized: String.LocalizationValue(title))
        return local == title ? [] : [local]
    }

    /// Commands plus the saved assistant actions.
    @MainActor
    static func items(_ session: EditorSession) -> [PaletteItem] {
        allItems + session.ai.savedActions.map {
            PaletteItem(id: "action.\($0.id)", title: $0.name, subtitle: "Action", keywords: ["action", "saved", "macro"],
                        action: .savedAction($0.id.uuidString))
        }
    }

    @MainActor
    static func rows(for query: String, session: EditorSession, limit: Int = 9, recentsWhenEmpty: Bool = true) -> [PaletteRow] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let items = items(session)
        guard !q.isEmpty else {
            // Nothing typed yet: what you used last.
            guard recentsWhenEmpty else { return [] }
            let recents = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
            return recents.compactMap { id in items.first { $0.id == id } }.map(PaletteRow.item)
        }
        let results = CommandSearch.search(q, in: items, limit: limit, usage: usage)
        var rows = results.map { PaletteRow.item($0.item) }
        if CommandSearch.looksLikeAssistantRequest(q, bestScore: results.first?.score) {
            rows.insert(.ask(q), at: 0)
        } else {
            rows.append(.ask(q))
        }
        return rows
    }

    @MainActor
    static func ask(_ text: String, session: EditorSession) {
        session.showLayersPanel = true
        session.inspectorTab = .ai
        session.ai.ask(text)
    }

    @MainActor
    static func run(_ row: PaletteRow, session: EditorSession) {
        switch row {
        case .ask(let q):
            ask(q, session: session)
        case .item(let item):
            guard session.runPaletteItem(item) else { NSSound.beep(); return }
            recordUse(item.id)
        }
    }

    static let usageKey = "palette.usage"

    /// How often each item was run from the palette or the omnibar.
    static var usage: [String: CommandUsage] {
        guard let data = UserDefaults.standard.data(forKey: usageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: CommandUsage].self, from: data)) ?? [:]
    }

    static func recordUse(_ id: String) {
        var recents = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
        recents.removeAll { $0 == id }
        recents.insert(id, at: 0)
        UserDefaults.standard.set(Array(recents.prefix(6)), forKey: recentsKey)
        var table = usage
        CommandUsage.record(id, in: &table)
        if let data = try? JSONEncoder().encode(table) { UserDefaults.standard.set(data, forKey: usageKey) }
    }

    static func symbol(_ item: PaletteItem) -> String {
        switch item.action {
        case .tool(let raw): ToolID(rawValue: raw)?.symbolName ?? "hammer"
        case .preset: "camera.filters"
        case .savedAction: "bookmark"
        case .command(let id):
            if id.filterKind != nil { "camera.aperture" } else if id.adjustmentKind != nil { "slider.horizontal.3" } else { "command" }
        }
    }
}

/// A row as the web app shows it: category in small capitals, then the title.
struct PaletteRowView: View {
    let row: PaletteRow
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            switch row {
            case .item(let item):
                Text(item.subtitle.uppercased())
                    .font(.caption2.weight(.medium))
                    .kerning(0.6)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .frame(width: 92, alignment: .leading)
                Image(systemName: Palette.symbol(item)).frame(width: 16).foregroundStyle(Theme.muted)
                Text(LocalizedStringKey(item.title)).lineLimit(1)
                Spacer()
                if case .command(let id) = item.action, let s = CommandRegistry.standard.descriptor(for: id)?.shortcut {
                    Text(s.display).font(.caption.monospaced()).foregroundStyle(Theme.muted)
                }
            case .ask(let q):
                Text("ASSISTANT")
                    .font(.caption2.weight(.medium))
                    .kerning(0.6)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 92, alignment: .leading)
                Image(systemName: "sparkles").frame(width: 16).foregroundStyle(Theme.accent)
                Text("Ask the assistant: “\(q)”").lineLimit(1)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(selected ? Theme.accent.opacity(0.28) : .clear, in: .rect(cornerRadius: 7))
        .contentShape(.rect)
    }
}

/// ⌘K: fuzzy search over every command, tool, filter, adjustment and preset.
/// Text that reads like a request goes to the assistant instead.
struct CommandPalette: View {
    let session: EditorSession
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    var body: some View {
        let rows = Palette.rows(for: query, session: session)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("⌘K").font(.callout.monospaced()).foregroundStyle(Theme.muted)
                TextField("Search commands, or ask for an edit…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { run(rows, index: selection) }
                    .onKeyPress(.downArrow) { selection = min(selection + 1, max(rows.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                    .onKeyPress(.escape) { session.isPaletteOpen = false; return .handled }
                    .onChange(of: query) { selection = 0 }
                Text("↑↓ · Enter · Esc").font(.caption).foregroundStyle(Theme.muted)
            }
            .padding(16)
            if !rows.isEmpty {
                Divider().overlay(Theme.edge)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            PaletteRowView(row: row, selected: index == selection)
                                .onTapGesture { run(rows, index: index) }
                        }
                    }
                    .padding(6)
                }
                .frame(height: min(CGFloat(rows.count) * 36 + 12, 380))
            } else {
                Text("Try “blur”, “curves”, “brush”, or describe an edit: “make it look like film”.")
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 620)
        .panelSurface(cornerRadius: 14)
        .task {
            // The canvas holds the keyboard; take it once the field is in the window.
            try? await Task.sleep(for: .milliseconds(60))
            focused = true
        }
    }

    private func run(_ rows: [PaletteRow], index: Int) {
        guard rows.indices.contains(index) else { return }
        session.isPaletteOpen = false
        Palette.run(rows[index], session: session)
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
        case .savedAction(let id):
            guard let action = ai.savedActions.first(where: { $0.id.uuidString == id }) else { return false }
            showAI(.assistant)
            ai.run(action)
        }
        return true
    }
}

/// The omnibar: type a command or describe an edit, right on the canvas.
/// ↩ runs the best match (or asks the assistant when the text reads like a
/// request), ⌘↩ always asks the assistant.
struct Omnibar: View {
    let session: EditorSession
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    var body: some View {
        let rows = focused ? Palette.rows(for: query, session: session, limit: 5, recentsWhenEmpty: false) : []
        VStack(spacing: 8) {
            if focused, query.isEmpty {
                // As in the web app: things to generate on an empty canvas, otherwise things to do to the image.
                let blank = session.isUntouchedBlank
                let smart = blank ? [] : session.ai.smartSuggestions
                HStack(spacing: 6) {
                    Text("Try").foregroundStyle(Theme.muted)
                    // On-device analysis of this image first (instant and free), then the general ideas.
                    ForEach(smart, id: \.self) { id in
                        Button {
                            finish()
                            Palette.recordUse(id.rawValue)
                            session.perform(id)
                        } label: {
                            Label(smartTitle(id), systemImage: "wand.and.sparkles").labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .overlay { Capsule().strokeBorder(Theme.accent.opacity(0.6)) }
                        .contentShape(.capsule)
                        .help("Suggested for this image (analysed on this Mac)")
                    }
                    ForEach((blank ? Self.generateSuggestions : Self.editSuggestions).prefix(max(2, 5 - smart.count)), id: \.self) { suggestion in
                        Button(LocalizedStringKey(suggestion)) {
                            finish()
                            Palette.ask(blank ? "generate \(String(localized: String.LocalizationValue(suggestion)))"
                                              : String(localized: String.LocalizationValue(suggestion)), session: session)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .overlay { Capsule().strokeBorder(Theme.edge) }
                        .contentShape(.capsule)
                    }
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .panelSurface(cornerRadius: 12)
            }
            if !rows.isEmpty {
                VStack(spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        PaletteRowView(row: row, selected: index == selection)
                            .onTapGesture { run(row) }
                    }
                }
                .padding(6)
                .panelSurface(cornerRadius: 12)
            }
            HStack(spacing: 12) {
                Image(systemName: "sparkles").font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.accent)
                TextField("Describe an edit, or type a command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { if rows.indices.contains(selection) { run(rows[selection]) } }
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        let text = query.trimmingCharacters(in: .whitespaces)
                        guard !text.isEmpty else { return .handled }
                        finish()
                        Palette.ask(text, session: session)
                        return .handled
                    }
                    .onKeyPress(.downArrow) { selection = min(selection + 1, max(rows.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                    .onKeyPress(.escape) { finish(); return .handled }
                    .onChange(of: query) { selection = 0 }
                    .accessibilityLabel("Describe an edit, or type a command")
                Text("↩ run · ⌘↩ ask AI · ⌘K palette")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .fixedSize()
            }
            .padding(.horizontal, 18)
            .frame(height: 52)
            .panelSurface(cornerRadius: 12)
        }
        .frame(width: 720)
        .onChange(of: focused) { if focused { session.ai.refreshInsights() } }
    }

    private func smartTitle(_ id: CommandID) -> String {
        if id == .autoStraighten, let tilt = session.ai.insights?.horizonDegrees {
            return String(localized: "Straighten \(String(format: "%.1f", abs(tilt)))°")
        }
        let title = CommandRegistry.standard.descriptor(for: id)?.title ?? id.rawValue
        return String(localized: String.LocalizationValue(title))
    }

    private static let generateSuggestions = ["a sunset over mountains", "a cute robot mascot", "a watercolor forest cabin",
                                              "a neon city street at night"]
    private static let editSuggestions = ["make it warmer", "add curves", "relight", "remove background", "vintage look"]

    private func run(_ row: PaletteRow) {
        finish()
        Palette.run(row, session: session)
    }

    /// Clears the field and hands the keyboard back to the canvas.
    private func finish() {
        query = ""
        focused = false
        NSApp.keyWindow?.makeFirstResponder(NSApp.keyWindow?.contentView)
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
