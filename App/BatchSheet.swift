import AppKit
import GlimmerAI
import ImageIO
import GlimmerCore
import GlimmerRender
import SwiftUI
import UniformTypeIdentifiers

/// What a batch does to every image.
enum BatchRecipe: Hashable {
    case convertOnly
    case autoEnhance
    case removeBackground
    case preset(String)
    case action(UUID)
}

/// Runs a recipe over many files and writes the results to a folder. The work
/// happens off the main thread, one file at a time, with the same headless
/// code that Shortcuts uses.
@MainActor
@Observable
final class BatchRunner {
    struct Outcome: Identifiable {
        let id = UUID()
        let source: URL
        var output: URL?
        var error: String?
    }

    private(set) var outcomes: [Outcome] = []
    private(set) var isRunning = false
    private(set) var done = 0
    private(set) var total = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    func start(files: [URL], recipe: BatchRecipe, options: ExportOptions, destination: URL, suffix: String) {
        guard !isRunning, !files.isEmpty else { return }
        let action: SavedAction?
        if case .action(let id) = recipe { action = SavedAction.load().first { $0.id == id } } else { action = nil }
        outcomes = []
        done = 0
        total = files.count
        isRunning = true
        task = Task { [weak self] in
            let access = destination.startAccessingSecurityScopedResource()
            defer { if access { destination.stopAccessingSecurityScopedResource() } }
            for url in files {
                if Task.isCancelled { break }
                let result: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
                    Result { try Self.process(url, recipe: recipe, action: action, options: options,
                                              destination: destination, suffix: suffix) }
                }.value
                guard let self else { return }
                switch result {
                case .success(let out): self.outcomes.append(Outcome(source: url, output: out))
                case .failure(let error):
                    self.outcomes.append(Outcome(source: url, error: (error as? HeadlessEditor.Failure)?.message
                                                 ?? error.localizedDescription))
                }
                self.done += 1
            }
            self?.isRunning = false
        }
    }

    func cancel() { task?.cancel() }

    // MARK: Rating

    private(set) var ratings: [URL: PhotoQuality.Rating] = [:]
    private(set) var isRating = false
    private(set) var rated = 0

    /// Rates the photos on this Mac (aesthetics and sharpness), one at a time.
    func rate(_ files: [URL]) {
        guard !isRating, !isRunning else { return }
        let todo = files.filter { ratings[$0] == nil }
        guard !todo.isEmpty else { return }
        isRating = true
        rated = 0
        task = Task { [weak self] in
            for url in todo {
                if Task.isCancelled { break }
                let rating = await Task.detached(priority: .userInitiated) { Self.thumbnail(url).map(PhotoQuality.rate) }.value
                guard let self else { return }
                if let rating { self.ratings[url] = rating }
                self.rated += 1
            }
            self?.isRating = false
        }
    }

    /// A ~1024-pixel copy straight from the file (much faster than decoding it all).
    nonisolated static func thumbnail(_ url: URL) -> CGImage? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1024,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }

    nonisolated static func process(_ url: URL, recipe: BatchRecipe, action: SavedAction?, options: ExportOptions,
                                    destination: URL, suffix: String) throws -> URL {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var state = try HeadlessEditor.document(contentsOf: url)
        switch recipe {
        case .convertOnly: break
        case .autoEnhance: state = try HeadlessEditor.autoEnhance(state)
        case .removeBackground: state = try HeadlessEditor.removeBackground(state)
        case .preset(let id):
            guard let preset = Preset.all.first(where: { $0.id == id }) else {
                throw HeadlessEditor.Failure(message: "That preset no longer exists.")
            }
            state = try HeadlessEditor.applyPreset(preset, to: state)
        case .action:
            guard let action else { throw HeadlessEditor.Failure(message: "That action no longer exists.") }
            state = try HeadlessEditor.run(action, on: state)
        }
        let image = try ImageExporter.convert(try ImageExporter.flatten(state, context: HeadlessEditor.metal), options: options)
        let data = try ImageExporter.encode(image, options: options)
        let out = uniqueURL(in: destination, base: url.deletingPathExtension().lastPathComponent + suffix,
                            ext: options.format == .jpeg ? "jpg" : options.format.contentType.preferredFilenameExtension ?? options.format.rawValue)
        try data.write(to: out, options: .atomic)
        return out
    }

    /// `base.ext` in `folder`, numbered if that name is taken.
    nonisolated static func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        var candidate = folder.appending(path: "\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = folder.appending(path: "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}

struct BatchSheet: View {
    @Bindable var session: EditorSession
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var recipe: BatchRecipe = .autoEnhance
    @State private var options = ExportOptions(format: .jpeg)
    @State private var destination: URL?
    @State private var suffix = ""
    @State private var runner = BatchRunner()
    @State private var isTargeted = false

    static let imageTypes: [UTType] = [.image, UTType(exportedAs: "com.brattoo.glimmer.document")]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    fileList
                    HStack {
                        Button("Add Images…", systemImage: "plus") { addFiles() }
                        if !files.isEmpty {
                            Button("Clear") { files = [] }
                        }
                        Spacer()
                        Text("\(files.count) images").foregroundStyle(.secondary).monospacedDigit()
                    }
                    if !files.isEmpty { ratingBar }
                } header: {
                    Text("Images")
                }
                Section {
                    Picker("Apply", selection: $recipe) {
                        Text("Auto Enhance").tag(BatchRecipe.autoEnhance)
                        Text("Remove Background").tag(BatchRecipe.removeBackground)
                        Text("Nothing (convert only)").tag(BatchRecipe.convertOnly)
                        Divider()
                        ForEach(Preset.all, id: \.id) { p in Text(LocalizedStringKey(p.name)).tag(BatchRecipe.preset(p.id)) }
                        if !session.ai.savedActions.isEmpty {
                            Divider()
                            ForEach(session.ai.savedActions) { a in Text(a.name).tag(BatchRecipe.action(a.id)) }
                        }
                    }
                    if case .action = recipe {
                        Text("Steps that need the window or a paid AI job are not run in a batch.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if recipe == .removeBackground, !options.format.supportsAlpha {
                        Text("JPEG has no transparency: the background turns white. Choose PNG, HEIC or WebP to keep it.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Recipe")
                }
                Section {
                    Picker("Format", selection: $options.format) {
                        ForEach(ExportOptions.Format.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
                    }
                    if options.format.hasQuality {
                        LabeledContent("Quality") {
                            HStack {
                                Slider(value: $options.quality, in: 0.1...1)
                                    .accessibilityValue(Text(options.quality, format: .percent.precision(.fractionLength(0))))
                                Text(options.quality, format: .percent.precision(.fractionLength(0)))
                                    .monospacedDigit().frame(width: 44, alignment: .trailing)
                            }
                        }
                    }
                    ExportLimitsFields(options: $options)
                    LabeledContent("Save to") {
                        HStack {
                            Text(destination?.lastPathComponent ?? String(localized: "Choose a folder"))
                                .foregroundStyle(destination == nil ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.middle)
                            Button("Choose…") { chooseDestination() }
                        }
                    }
                    TextField("Name suffix", text: $suffix, prompt: Text("e.g. -edited"))
                } header: {
                    Text("Output")
                }
                if runner.total > 0 {
                    Section {
                        ProgressView(value: Double(runner.done), total: Double(max(runner.total, 1))) {
                            Text(runner.isRunning ? "Processing \(runner.done + 1) of \(runner.total)…"
                                                  : "Finished \(runner.outcomes.filter { $0.error == nil }.count) of \(runner.total)")
                        }
                        ForEach(runner.outcomes.filter { $0.error != nil }) { o in
                            Label("\(o.source.lastPathComponent): \(o.error ?? "")", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange).font(.callout)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if !runner.isRunning, runner.done > 0, let destination {
                    Button("Show in Finder") {
                        let written = runner.outcomes.compactMap(\.output)
                        NSWorkspace.shared.activateFileViewerSelecting(written.isEmpty ? [destination] : written)
                    }
                }
                Spacer()
                if runner.isRunning {
                    Button("Stop") { runner.cancel() }
                } else {
                    Button("Close", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Button("Process \(files.count) Images") {
                    guard let destination else { return }
                    runner.start(files: files, recipe: recipe, options: options, destination: destination, suffix: suffix)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(files.isEmpty || destination == nil || runner.isRunning || runner.isRating)
            }
            .padding()
        }
        .frame(width: 520, height: 660)
    }

    private var fileList: some View {
        ZStack {
            if files.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "photo.stack").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Drop images or folders here").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 110)
            } else {
                List {
                    ForEach(files, id: \.self) { url in
                        HStack {
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if let r = runner.ratings[url] {
                                if r.isBlurry { badge("Blurry", .orange) }
                                if r.isUtility { badge("Document", .secondary) }
                                Text(String(repeating: "★", count: r.stars) + String(repeating: "☆", count: 5 - r.stars))
                                    .font(.caption).foregroundStyle(Theme.accent)
                                    .help("Aesthetics \(String(format: "%.2f", r.aesthetics)), sharpness \(Int(r.sharpness * 100)) %")
                            }
                            if let o = runner.outcomes.first(where: { $0.source == url }) {
                                Image(systemName: o.error == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(o.error == nil ? .green : .orange)
                            }
                        }
                    }
                    .onDelete { files.remove(atOffsets: $0) }
                }
                .frame(minHeight: 110, maxHeight: 160)
            }
        }
        .overlay { if isTargeted { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent, lineWidth: 2) } }
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private func badge(_ text: LocalizedStringKey, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(color.opacity(0.6)))
    }

    /// Rate the photos, then sort them or keep only the best.
    @ViewBuilder private var ratingBar: some View {
        let ratedAll = files.allSatisfy { runner.ratings[$0] != nil }
        HStack {
            if runner.isRating {
                ProgressView(value: Double(runner.rated), total: Double(max(files.count, 1)))
                    .frame(width: 120)
                Text("Rating…").foregroundStyle(.secondary)
            } else if !ratedAll {
                Button("Rate Photos", systemImage: "star.leadinghalf.filled") { runner.rate(files) }
                    .help("Scores every photo for aesthetics and sharpness on this Mac, so you can keep the best")
            } else {
                Button("Best First", systemImage: "arrow.up.arrow.down") {
                    files.sort { (runner.ratings[$0]?.score ?? -9) > (runner.ratings[$1]?.score ?? -9) }
                }
                Menu("Keep") {
                    Button("Without blurry photos") { files.removeAll { runner.ratings[$0]?.isBlurry == true } }
                    Button("Without documents and screenshots") { files.removeAll { runner.ratings[$0]?.isUtility == true } }
                    Divider()
                    Button("4 stars and up") { files.removeAll { (runner.ratings[$0]?.stars ?? 0) < 4 } }
                    Button("Best half") { keepBest(fraction: 0.5) }
                    Button("Best quarter") { keepBest(fraction: 0.25) }
                }
                .fixedSize()
            }
            Spacer()
            if ratedAll, !runner.isRating {
                let blurry = files.filter { runner.ratings[$0]?.isBlurry == true }.count
                if blurry > 0 { Text("\(blurry) blurry").foregroundStyle(.orange).font(.callout) }
            }
        }
    }

    private func keepBest(fraction: Double) {
        let keep = max(1, Int((Double(files.count) * fraction).rounded(.up)))
        let best = Set(files.sorted { (runner.ratings[$0]?.score ?? -9) > (runner.ratings[$1]?.score ?? -9) }.prefix(keep))
        files.removeAll { !best.contains($0) }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = Self.imageTypes
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    /// Adds image files, looking one level into folders.
    private func add(_ urls: [URL]) {
        var found: [URL] = []
        for url in urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, url.pathExtension.lowercased() != "glimmer" {
                let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentTypeKey],
                                                                          options: [.skipsHiddenFiles])) ?? []
                found += items.filter(Self.isImage).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else if Self.isImage(url) {
                found.append(url)
            }
        }
        files += found.filter { !files.contains($0) }
    }

    private static func isImage(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "glimmer" { return true }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .image) == true
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Save Here")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destination = url
    }
}
