import Sparkle
import SwiftUI

/// Sparkle updates. Stays inactive until the build carries an EdDSA public key
/// (`SUPublicEDKey`, set by scripts/release.sh), so development builds never
/// try to update themselves.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController?
    @Published private(set) var canCheck = false

    var isConfigured: Bool { controller != nil }

    /// Whether this build may ask for updates at all: a release build under Glimmer's own bundle id, with the key.
    /// A Debug build, a guest copy or any copy under another id never starts Sparkle, whatever key or feed stands
    /// in its Info.plist (scripts/check-fetching.sh holds this).
    static var mayUpdate: Bool {
        #if DEBUG
        return false
        #else
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        return !key.isEmpty && Bundle.main.bundleIdentifier == "com.brattoo.glimmer"
        #endif
    }

    private init() {
        guard Self.mayUpdate else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

struct CheckForUpdatesCommand: Commands {
    @ObservedObject private var updater = Updater.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if updater.isConfigured {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
            }
        }
    }
}
