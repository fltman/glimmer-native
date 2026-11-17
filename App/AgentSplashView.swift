import AppKit
import SwiftUI

/// Shown at launch: the line to hand to an AI agent so it can learn Glimmer's
/// local API. Also under Help › Agent Access.
struct AgentSplashView: View {
    static let showAtLaunchKey = "agent.splashAtLaunch"
    /// The Neon icon family: violet glow on near-black.
    static let neon = Color(red: 0xC4 / 255, green: 0x5C / 255, blue: 0xFF / 255)
    static let ink = Color(red: 0.05, green: 0.04, blue: 0.08)
    let dismiss: () -> Void
    @State private var server = AgentServer.shared
    @State private var copied = false
    @AppStorage(Self.showAtLaunchKey) private var showAtLaunch = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    // The icon's own shape is a little inside its square: the glow follows that.
                    .background(GlowPulse(color: NSColor(Self.neon), strength: 0.5, radius: 18, cornerRadius: 16).padding(7))
                    .accessibilityHidden(true)  // the heading names the app
                VStack(alignment: .leading, spacing: 2) {
                    Text("Glimmer").font(.largeTitle.bold())
                        .shadow(color: Self.neon.opacity(0.6), radius: 10)
                        .accessibilityAddTraits(.isHeader)
                    Text("A photo editor for the Mac that agents can drive too.")
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("For your agent").font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("Paste this into Claude or another AI agent. It fetches the guide from Glimmer on this Mac and can then open, edit and export images in your open windows.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let prompt = server.agentPrompt {
                    HStack(alignment: .top, spacing: 8) {
                        // The field is named by this group, never by a label on the selectable text itself:
                        // that makes SwiftUI ask itself for the label without end, and the app crashes as
                        // soon as VoiceOver reads it (found in the Assistant's messages, 2026-11-16).
                        VStack(spacing: 0) {
                            Text(verbatim: prompt)
                                .font(.system(.callout, design: .monospaced))
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Self.neon.opacity(0.8)))
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Text for your agent")
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(prompt, forType: .string)
                            copied = true
                            AccessibilityNotification.Announcement(String(localized: "Copied")).post()
                            Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                        } label: {
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .frame(minWidth: 70)
                                .foregroundStyle(Self.ink)  // dark on neon: 5.9 : 1 (white is 3.3 : 1)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .tint(Self.neon)
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                    }
                } else if let failure = server.failure {
                    StatusLine(.error, verbatim: failure)
                } else {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Starting the server for agents")
                }
            }
            HStack {
                Toggle("Show at launch", isOn: $showAtLaunch)
                Spacer()
                Button { dismiss() } label: {
                    Text("Close").foregroundStyle(Self.ink)  // dark on neon, like Copy (white is 3.3 : 1)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(Self.ink)
        .tint(Self.neon)
        .environment(\.colorScheme, .dark)
    }
}
