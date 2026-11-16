import AppKit

/// The app's own sounds, in one place, so a test copy can be silent by construction (the
/// series' rule, 2026-11-16): `scripts/test-app.sh` always starts its copy with `-quiet YES`,
/// and then nothing here sounds. The system volume is never touched.
/// (Not covered: the alert sound AppKit itself plays for a key nothing handles. Test scripts
/// send keys only to a sheet or panel that takes them.)
enum AppSound {
    static let isQuiet = UserDefaults.standard.bool(forKey: "quiet")

    static func beep() {
        guard !isQuiet else { return }
        NSSound.beep()
    }
}
