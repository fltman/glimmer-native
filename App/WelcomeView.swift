import AppKit
import SwiftUI

/// First-launch introduction. Also under Help › Welcome to Glimmer.
struct WelcomeView: View {
    static let shownKey = "onboarding.welcomeShown"
    let dismiss: () -> Void
    @Environment(\.openSettings) private var openSettings

    private let features: [(String, LocalizedStringKey, LocalizedStringKey)] = [
        ("square.3.layers.3d", "A real layer editor", "Layers, groups, masks, adjustment layers, layer styles, smart objects and text — non-destructive, in 16-bit linear color."),
        ("paintbrush.pointed", "Paint and retouch", "Brushes with pressure, clone and healing, dodge and burn, liquify and 14 filters that respect your selection."),
        ("sparkles", "AI with your own key", "Generate, fill, expand, relight and more through OpenRouter. Subject selection, depth blur and background removal run on this Mac."),
        ("sparkle.magnifyingglass", "Just ask", "Press ⌘K to find any command, or describe an edit and the assistant plans it with the editor's own tools."),
    ]

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)  // the heading names the app
                Text("Welcome to Glimmer").font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("A photo editor for the Mac, with AI where it helps.")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 16) {
                ForEach(features, id: \.0) { symbol, title, text in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: symbol)
                            .font(.title2)
                            .foregroundStyle(.tint)
                            .frame(width: 34)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(.headline)
                            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    // One stop per feature: its title, then what it does.
                    .accessibilityElement(children: .combine)
                }
            }
            HStack {
                Button("Add OpenRouter Key…") {
                    UserDefaults.standard.set("ai", forKey: SettingsView.tabKey)
                    openSettings()
                }
                Spacer()
                Button("Open Image…") {
                    dismiss()
                    // Glimmer's own panel: images, web projects and .glimmer documents.
                    DocumentOpener.shared.showOpenPanel()
                }
                Button("New Document") {
                    dismiss()
                    DocumentOpener.shared.showNewDocumentWindow()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 560)
    }
}
