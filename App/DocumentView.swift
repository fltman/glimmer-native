import GlimmerCore
import GlimmerRender
import GlimmerTools
import SwiftUI

struct DocumentView: View {
    @State private var session: EditorSession
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openSettings) private var openSettings
    @Environment(\.controlActiveState) private var activeState
    @AppStorage(Preferences.showOmnibarKey) private var showOmnibar = true
    @AppStorage(SelectionBar.showKey) private var showSelectionBar = true

    init(document: GlimmerDocument) {
        _session = State(initialValue: EditorSession(document: document))
    }

    var body: some View {
        CanvasView(session: session)
            .overlay(alignment: .leading) {
                if session.showTools, !session.interfaceHidden {
                    ToolPalette(session: session)
                        .padding(.leading, 12)
                }
            }
            .overlay(alignment: .topLeading) {
                if !session.interfaceHidden {
                    GeometryReader { geo in
                        // Never under the AI, Tools, Layers and Export chips at the top right.
                        TitleChip(session: session)
                            .frame(maxWidth: max(180, geo.size.width - 84 - 360), alignment: .leading)
                            .padding(.leading, 84)  // clear of the window buttons
                            .padding(.top, 10)
                    }
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .top) {
                if !session.interfaceHidden {
                    ToolOptionsBar(session: session)
                        .padding(.top, 48)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if session.showNavigator, !session.interfaceHidden {
                    NavigatorView(session: session, canvas: session.canvas).padding(12)
                }
            }
            .overlay {
                if showSelectionBar, !session.interfaceHidden {
                    GeometryReader { geo in SelectionBar(session: session, viewSize: geo.size) }
                }
            }
            .overlay(alignment: .bottom) {
                if showOmnibar, !session.interfaceHidden, session.liquify == nil, session.transformSession == nil, session.cropSession == nil,
                   !session.isPaletteOpen {
                    Omnibar(session: session).padding(.bottom, 16)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !session.interfaceHidden {
                    VStack(alignment: .trailing, spacing: 10) {
                        ChromeBar(session: session)
                        if session.showLayersPanel && !session.classicLayout {
                            SidePanel(session: session, docked: false)
                        }
                    }
                    .padding(.top, 10)
                    .padding(.trailing, 12)
                    .padding(.bottom, 12)
                }
            }
            .overlay(alignment: .top) {
                if session.isPaletteOpen {
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.35)
                            .onTapGesture { session.isPaletteOpen = false }
                        CommandPalette(session: session).padding(.top, 110)
                    }
                    .ignoresSafeArea()
                }
            }
            .overlay(alignment: .topLeading) {
                // Floating, non-modal: the canvas stays visible for the live preview.
                if let item = session.filterDialog.map(FilterDialogItem.init) {
                    FilterSheet(session: session, settings: item.settings)
                        .id(item.id)
                        .panelSurface(cornerRadius: 14)
                        .padding(.top, 96)
                        .padding(.leading, session.showTools ? 104 : 14)
                }
            }
            .overlay {
                if showsStartCard { StartCard(session: session) }
            }
            .overlay(alignment: .top) {
                // Brief, non-blocking feedback ("nothing to straighten" and the like).
                if let toast = session.toast {
                    Text(toast)
                        .font(.callout)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .panelSurface(cornerRadius: 15)
                        .padding(.top, 96)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .id(toast)
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            .animation(.snappy, value: session.toast)
            .ignoresSafeArea(.container, edges: .top)
            .safeAreaInset(edge: .trailing, spacing: 0) {
                if session.classicLayout, !session.interfaceHidden {
                    SidePanel(session: session, docked: true).ignoresSafeArea(.container, edges: .top)
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .sheet(item: Binding(get: { session.selectionDialog.map(SelectionDialogItem.init) },
                                 set: { session.selectionDialog = $0?.id })) { item in
                SelectionModifySheet(session: session, command: item.id)
            }
            .sheet(isPresented: $session.isExportSheetPresented) {
                ExportSheet(session: session)
            }
            .sheet(isPresented: $session.isCanvasSizePresented) {
                CanvasSizeSheet(session: session)
            }
            #if GLIMMER_PSD
            .sheet(isPresented: $session.isImportReportPresented) {
                ImportReportSheet(session: session)
            }
            .sheet(isPresented: $session.isPSDExportPresented) {
                PSDExportSheet(session: session)
            }
            #endif
            #if GLIMMER_RAW
            .sheet(isPresented: $session.isRawDevelopPresented) {
                RawDevelopSheet(session: session)
            }
            #endif
            .sheet(isPresented: $session.isImageSizePresented) {
                ImageSizeSheet(session: session)
            }
            .sheet(isPresented: $session.isLayerStylePresented) {
                LayerStyleSheet(session: session)
            }
            .sheet(isPresented: $session.isBatchSheetPresented) {
                BatchSheet(session: session)
            }
            .onChange(of: session.document.diskNotice) { _, notice in
                guard let notice else { return }
                session.document.diskNotice = nil
                session.errorMessage = notice
            }
            .alert("Glimmer", isPresented: Binding(
                get: { session.errorMessage != nil },
                set: { if !$0 { session.errorMessage = nil } }
            )) {
                Button("OK") { session.errorMessage = nil }
            } message: {
                Text(session.errorMessage ?? "")
            }
            #if GLIMMER_HEAL
            .alert(Text("This is a large area to heal"), isPresented: Binding(
                get: { session.healWarning != nil },
                set: { if !$0 { session.healWarning = nil } }
            )) {
                Button("Fill Anyway") {
                    session.healWarning = nil
                    session.ai.healSelection(allowLarge: true)
                }
                Button("Cancel", role: .cancel) { session.healWarning = nil }
            } message: {
                Text("\(session.healWarning ?? "")\n\nGenerative Fill (AI ▸ Generative Fill…) can replace larger areas.")
            }
            #endif
            .alert(Text(verbatim: session.textNotice?.title ?? ""), isPresented: Binding(
                get: { session.textNotice != nil },
                set: { if !$0 { session.textNotice = nil } }
            ), presenting: session.textNotice) { notice in
                switch notice.kind {
                case .firstUse:
                    Button("Send") { notice.proceed?() }
                    Button("Not Now", role: .cancel) {}
                case .cantSee:
                    Button("Open Settings…") { openSettings() }
                    Button("OK", role: .cancel) {}
                }
            } message: { notice in
                Text(verbatim: notice.message)
            }
            .alert(Text("Rasterize text?"), isPresented: Binding(
                get: { session.rasterizeTextConfirmation != nil },
                set: { if !$0 { session.rasterizeTextConfirmation = nil } }
            ), presenting: session.rasterizeTextConfirmation) { count in
                Button("Rasterize", role: .destructive) { session.commitTransform(confirmed: true) }
                Button("Cancel", role: .cancel) {}
            } message: { count in
                count == 1
                    ? Text("Distort and perspective can't keep text editable: the text layer becomes pixels and can't be edited as text anymore. Undo brings the text back.")
                    : Text("Distort and perspective can't keep text editable: \(count) text layers become pixels and can't be edited as text anymore. Undo brings the text back.")
            }
            .alert(Text("\(session.offlineSibling?.displayName ?? "") is not running."), isPresented: Binding(
                get: { session.offlineSibling != nil },
                set: { if !$0 { session.offlineSibling = nil } }
            ), presenting: session.offlineSibling) { app in
                Button("Open \(app.displayName)") { AIController.launch(app, session: session) }
                Button("Cancel", role: .cancel) {}
            } message: { app in
                Text("The assistant needs \(app.displayName) for this. Open it, then ask again.")
            }
            .preferredColorScheme(.dark)
            .tint(Theme.accentFill)  // prominent buttons carry white text
            .focusedSceneValue(\.editorSession, session)
            .onAppear {
                session.undoManager = undoManager
                // Only a session that has a window is offered to agents.
                AgentRegistry.shared.register(session)
                DocumentOpener.shared.claimLink(for: session)
                #if GLIMMER_PSD
                DocumentOpener.shared.claimImportReport(for: session)
                #endif
            }
            .onDisappear { AgentRegistry.shared.unregister(session) }
            .onChange(of: activeState) { _, state in if state == .key { AgentRegistry.shared.markFront(session) } }
            .onChange(of: undoManager) { _, manager in session.undoManager = manager }
    }
}

extension DocumentView {
    /// An untouched, empty document greets you like the web app does.
    fileprivate var showsStartCard: Bool {
        !session.startCardDismissed && session.document.history.isEmpty && session.state.textureTileIDs.isEmpty
            && session.state.allLayers.count <= 1 && session.editingText == nil
    }
}

/// Logo, a line of guidance and the two ways in.
private struct StartCard: View {
    let session: EditorSession

    var body: some View {
        VStack(spacing: 20) {
            Image("GlimmerLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 180, height: 180)
                .clipShape(.rect(cornerRadius: 40, style: .continuous))
                .shadow(color: Color(red: 0.77, green: 0.36, blue: 1).opacity(0.35), radius: 24)
                .accessibilityLabel("Glimmer")
            Text("Drop a file anywhere, paste from your clipboard, or open one — or just describe an image in the bar below and AI generates it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: 380)
            HStack(spacing: 12) {
                Button("Open Image") { DocumentOpener.shared.showOpenPanel() }
                    .buttonStyle(.borderedProminent)
                Button("⌘K Commands") { session.isPaletteOpen = true }
                Button("Start Blank") { session.startCardDismissed = true }
            }
            .controlSize(.large)
        }
        .padding(36)
        .panelSurface(cornerRadius: 16)
    }
}

/// The buttons along the top right, as in the web app: AI, Tools, Layers, Export, ⌘K.
private struct ChromeBar: View {
    @Bindable var session: EditorSession

    var body: some View {
        HStack(spacing: 8) {
            ChromeChip(title: "AI", systemImage: "sparkles", isOn: session.showLayersPanel && session.inspectorTab == .ai) {
                toggle(.ai)
            }
            .help("Assistant and AI tools")
            ChromeChip(title: "Tools", systemImage: "wrench.and.screwdriver", isOn: session.showTools) {
                session.showTools.toggle()
            }
            .help("Show or hide the tools")
            ChromeChip(title: "Layers", systemImage: "square.3.layers.3d",
                       isOn: session.showLayersPanel && session.inspectorTab != .ai) {
                toggle(session.inspectorTab == .ai ? .layers : session.inspectorTab)
            }
            .help("Layers, paths, channels and history (⌥⌘L)")
            ChromeChip(title: "Export", systemImage: "square.and.arrow.down") { session.perform(.export) }
                .help("Export the image")
            ChromeChip(title: "Command Palette", systemImage: "command", showsTitle: false) { session.isPaletteOpen = true }
                .help("Search commands or ask the assistant (⌘K)")
        }
    }

    private func toggle(_ tab: EditorSession.InspectorTab) {
        if session.classicLayout {
            // The docked panel is always there; the chips just switch what it shows.
            session.inspectorTab = tab
            session.showLayersPanel = true
            return
        }
        let showing = session.showLayersPanel && (tab == .ai) == (session.inspectorTab == .ai)
        if showing {
            session.showLayersPanel = false
        } else {
            session.inspectorTab = tab
            session.showLayersPanel = true
        }
    }
}

/// The floating panel under the chips: the assistant, or layers/paths/channels/history.
private struct SidePanel: View {
    @Bindable var session: EditorSession
    /// Docked (classic layout): full height at the window's right edge, with every tab.
    let docked: Bool

    private var tabs: [EditorSession.InspectorTab] {
        docked ? EditorSession.InspectorTab.allCases : [.layers, .paths, .channels, .history]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if session.inspectorTab == .ai && !docked {
                    Text("ASSISTANT & AI").font(.caption.weight(.semibold)).kerning(1).foregroundStyle(Theme.muted)
                    Spacer(minLength: 8)
                } else {
                    Picker("Panel", selection: $session.inspectorTab) {
                        ForEach(tabs, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if !docked {
                    Button("Close", systemImage: "xmark") { session.showLayersPanel = false }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .padding(.top, docked ? 28 : 0)  // below the window buttons' row
            Divider().overlay(Theme.edge)
            Group {
                switch session.inspectorTab {
                case .layers: LayersPanel(session: session)
                case .paths: PathsPanel(session: session)
                case .channels: ChannelsPanel(session: session)
                case .history: HistoryPanel(session: session)
                case .ai: AIPanel(session: session, ai: session.ai)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 340)
        .modifier(SidePanelChrome(docked: docked))
    }
}

private struct SidePanelChrome: ViewModifier {
    let docked: Bool

    func body(content: Content) -> some View {
        if docked {
            content
                .background(Theme.panel)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.edge).frame(width: 1) }
        } else {
            content.frame(maxHeight: 640).panelSurface(cornerRadius: 12)
        }
    }
}

/// Logo, document name, size and zoom, top left (plus whatever is in progress).
private struct TitleChip: View {
    let session: EditorSession

    var body: some View {
        // A group named "Document status" whose parts are each read. A label on a combined
        // element replaced all of it: the name, the size and that the document is linked
        // (or has lost its link) were never spoken.
        content
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Document status")
    }

    private var content: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle").foregroundStyle(Theme.accent).accessibilityHidden(true)
            Text(session.linkedImage?.fileName ?? session.brokenLink?.link.fileName ?? session.explicitName ?? session.documentName).fontWeight(.medium).lineLimit(1)
            Text(verbatim: "\(session.state.width)×\(session.state.height)").foregroundStyle(.secondary)
            Text(session.canvas.zoom, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if session.paintsMask {
                Label("Editing mask", systemImage: "rectangle.dashed").foregroundStyle(.secondary)
            }
            if let link = session.linkedImage {
                Label("For \(link.requester) – ⌘S saves back", systemImage: "link")
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)  // shortens first when the window is narrow
                    .accessibilityLabel("Editing \(link.fileName) for \(link.requester). Command-S saves it back.")
            }
            if let broken = session.brokenLink {
                Label("For \(broken.link.requester) – can't save back", systemImage: "link.badge.plus")
                    .symbolVariant(.slash)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .layoutPriority(-1)
                    .help(broken.reason)
                    .accessibilityLabel("Was being edited for \(broken.link.requester). \(broken.reason)")
            }
            if session.isExporting {
                ProgressView().controlSize(.small)
                Text("Exporting…").foregroundStyle(.secondary)
            }
            if let job = session.ai.jobs.first(where: { $0.status == .running }) {
                ProgressView().controlSize(.small)
                (Text(LocalizedStringKey(job.title)) + Text(verbatim: "…")).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .panelSurface(cornerRadius: 8)
        .allowsHitTesting(false)
    }
}

private struct ToolPalette: View {
    @Bindable var session: EditorSession

    var body: some View {
        VStack(spacing: 6) {
            LazyVGrid(columns: [GridItem(.fixed(32), spacing: 2), GridItem(.fixed(32), spacing: 2)], spacing: 2) {
                ForEach(CanvasNSView.availableTools, id: \.self) { tool in
                    Button {
                        session.tool = tool
                    } label: {
                        // A Label (shown as its icon) gives the button its name for VoiceOver;
                        // an accessibilityLabel on the plain button didn't reach it.
                        Label(LocalizedStringKey(tool.title), systemImage: tool.symbolName)
                            .labelStyle(.iconOnly)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 32, height: 30)
                            .foregroundStyle(session.tool == tool ? Color.accentColor : .primary)
                            .background {
                                if session.tool == tool {
                                    RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.15))
                                }
                            }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(tool.helpText)
                    .accessibilityLabel(Text(LocalizedStringKey(tool.title)))
                    .accessibilityAddTraits(session.tool == tool ? .isSelected : [])
                }
            }
            ColorSwatches(session: session)
        }
        .padding(6)
        .fixedSize()
        .panelSurface(cornerRadius: 12)
    }
}

/// Foreground/background colours (X swaps, D resets).
private struct ColorSwatches: View {
    @Bindable var session: EditorSession
    @Environment(\.self) private var environment

    var body: some View {
        ZStack(alignment: .topLeading) {
            ColorPicker("Background", selection: Binding(
                get: { session.background.swiftUI.opacity(session.backgroundOpacity) },
                set: {
                    session.background = SRGBColor($0, in: environment)
                    session.backgroundOpacity = Self.alpha(of: $0)
                }), supportsOpacity: true)
                .labelsHidden()
                .frame(width: 40, height: 24)
                .offset(x: 22, y: 18)
            ColorPicker("Foreground", selection: Binding(
                get: { session.foreground.swiftUI.opacity(session.foregroundOpacity) },
                set: {
                    session.foreground = SRGBColor($0, in: environment)
                    session.foregroundOpacity = Self.alpha(of: $0)
                }), supportsOpacity: true)
                .labelsHidden()
                .frame(width: 40, height: 24)
        }
        .frame(width: 66, height: 44, alignment: .topLeading)
        .help("Foreground and background colours (X swaps, D resets)")
        HStack(spacing: 2) {
            Button { session.swapColors() } label: { Image(systemName: "arrow.left.arrow.right").frame(width: 30, height: 20) }
                .help("Swap foreground and background (X)")
                .accessibilityLabel("Swap colours")
            Button { session.resetColors() } label: { Image(systemName: "circle.lefthalf.filled").frame(width: 30, height: 20) }
                .help("Reset to black and white (D)")
                .accessibilityLabel("Reset colours")
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(Theme.muted)
        Button {
            showSwatches.toggle()
        } label: {
            Image(systemName: "swatchpalette").frame(width: 32, height: 22)
        }
        .buttonStyle(.plain)
        .help("Swatches")
        .accessibilityLabel("Swatches")
        .popover(isPresented: $showSwatches, arrowEdge: .trailing) {
            SwatchesView(session: session)
        }
    }

    @State private var showSwatches = false

    static func alpha(of color: Color) -> Double {
        Double(NSColor(color).usingColorSpace(.sRGB)?.alphaComponent ?? 1)
    }
}

/// A palette of colour swatches: click sets the foreground, ⌥-click the
/// background. Saved swatches persist across documents.
private struct SwatchesView: View {
    @Bindable var session: EditorSession
    @AppStorage("swatches.saved") private var savedData = Data()

    private static let defaults: [SRGBColor] = [
        SRGBColor(0, 0, 0), SRGBColor(0.25, 0.25, 0.25), SRGBColor(0.5, 0.5, 0.5), SRGBColor(0.75, 0.75, 0.75), SRGBColor(1, 1, 1),
        SRGBColor(0.86, 0.15, 0.15), SRGBColor(0.96, 0.45, 0.1), SRGBColor(0.98, 0.8, 0.1), SRGBColor(0.35, 0.72, 0.25),
        SRGBColor(0.1, 0.6, 0.55), SRGBColor(0.15, 0.55, 0.9), SRGBColor(0.3, 0.3, 0.8), SRGBColor(0.55, 0.3, 0.75),
        SRGBColor(0.9, 0.35, 0.6), SRGBColor(0.55, 0.36, 0.2), SRGBColor(0.96, 0.87, 0.72), SRGBColor(0.75, 0.55, 0.45),
        SRGBColor(0.35, 0.45, 0.3), SRGBColor(0.2, 0.25, 0.35), SRGBColor(0.95, 0.6, 0.55),
    ]

    private var saved: [SRGBColor] { (try? JSONDecoder().decode([SRGBColor].self, from: savedData)) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Swatches").font(.headline)
            grid(Self.defaults, removable: false)
            HStack {
                Text("Saved").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button("Add Foreground", systemImage: "plus") {
                    var s = saved
                    if !s.contains(session.foreground) { s.append(session.foreground) }
                    savedData = (try? JSONEncoder().encode(s)) ?? savedData
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Save the foreground colour")
            }
            if saved.isEmpty {
                Text("Click + to save the foreground colour.").font(.caption).foregroundStyle(.secondary)
            } else {
                grid(saved, removable: true)
            }
            Text("Click: foreground · ⌥-click: background").font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 236)
    }

    static func hex(_ c: SRGBColor) -> String {
        func b(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", b(c.r), b(c.g), b(c.b))
    }

    private func grid(_ colors: [SRGBColor], removable: Bool) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 8), count: 5), spacing: 8) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, c in
                // A real button, so the keyboard reaches it; ⌥-click sets the background.
                Button {
                    if NSEvent.modifierFlags.contains(.option) { session.background = c } else { session.foreground = c }
                } label: {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(c.swiftUI)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                    .contextMenu {
                        if removable {
                            Button("Remove") {
                                let s = saved.filter { $0 != c }
                                savedData = (try? JSONEncoder().encode(s)) ?? savedData
                            }
                        }
                    }
                    .accessibilityLabel(Text("Colour \(Self.hex(c))"))
                    .accessibilityHint(Text("Sets the foreground colour."))
                    .accessibilityAction(named: Text("Set as Background")) { session.background = c }
            }
        }
    }
}

extension ToolID {
    var title: String {
        switch self {
        case .move: "Move"
        case .hand: "Hand"
        case .rectangleMarquee: "Rectangular Marquee"
        case .ellipseMarquee: "Elliptical Marquee"
        case .lasso: "Lasso"
        case .polygonLasso: "Polygonal Lasso"
        case .magicWand: "Magic Wand"
        case .magicSelect: "Magic Select"
        case .brush: "Brush"
        case .eraser: "Eraser"
        case .paintBucket: "Paint Bucket"
        case .gradient: "Gradient"
        case .eyedropper: "Eyedropper"
        case .crop: "Crop"
        case .cloneStamp: "Clone Stamp"
        case .patternStamp: "Pattern Stamp"
        case .healingBrush: "Healing Brush"
        case .dodge: "Dodge"
        case .burn: "Burn"
        case .blur: "Blur"
        case .sharpen: "Sharpen"
        case .smudge: "Smudge"
        case .freeTransform: "Free Transform"
        case .type: "Type"
        case .pen: "Pen"
        case .shape: "Shape"
        }
    }

    var symbolName: String {
        switch self {
        case .move: "arrow.up.and.down.and.arrow.left.and.right"
        case .hand: "hand.raised"
        case .rectangleMarquee: "rectangle.dashed"
        case .ellipseMarquee: "circle.dashed"
        case .lasso: "lasso"
        case .polygonLasso: "skew"
        case .magicWand: "wand.and.stars"
        case .magicSelect: "wand.and.sparkles"
        case .brush: "paintbrush.pointed"
        case .eraser: "eraser"
        case .paintBucket: "drop.halffull"
        case .gradient: "square.bottomhalf.filled"
        case .eyedropper: "eyedropper"
        case .crop: "crop"
        case .cloneStamp: "seal"
        case .patternStamp: "square.grid.3x3.square"
        case .healingBrush: "bandage"
        case .dodge: "circle.lefthalf.filled"
        case .burn: "flame"
        case .blur: "drop.halffull"
        case .sharpen: "triangle"
        case .smudge: "hand.point.up"
        case .freeTransform: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left"
        case .type: "textformat"
        case .pen: "pencil.tip.crop.circle"
        case .shape: "square.on.circle"
        }
    }

    var helpText: String {
        if let key = shortcutKey { "\(title) (\(String(key).uppercased()))" } else { title }
    }
}
