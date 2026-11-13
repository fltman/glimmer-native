import XCTest

/// The critical flows end to end: new document, paint, undo, save, export.
/// Run with `scripts/uitest.sh` (drives the real app: keep hands off the mouse).
final class GlimmerUITests: XCTestCase {
    private var app: XCUIApplication!
    private var outDir: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        outDir = URL(fileURLWithPath: "/private/tmp/glimmer-uitests-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchArguments = ["-skipWelcome", "-ApplePersistenceIgnoreState", "YES", "-uiTestingNewDocument"]
        app.launch()
        XCTAssertTrue(canvas.waitForExistence(timeout: 15), "no document window")
    }

    override func tearDownWithError() throws {
        app.terminate()
        try? FileManager.default.removeItem(at: outDir)
    }

    private var canvas: XCUIElement { app.images["canvas"].firstMatch }

    private func paintStroke() {
        app.buttons["Brush"].firstMatch.click()
        let from = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4))
        let to = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6))
        from.press(forDuration: 0.1, thenDragTo: to)
    }

    private func showHistory() {
        let tab = app.radioButtons["History"].firstMatch
        if tab.exists { tab.click() } else { app.buttons["History"].firstMatch.click() }
    }

    /// Navigates the frontmost save panel to `directory`, names the file and saves.
    private func save(as name: String, in directory: URL) {
        let panel = app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.dialogs.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "no save panel")
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(directory.path + "\n")
        sleep(1)
        let nameField = panel.textFields.firstMatch
        nameField.click()
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText(name + "\n")
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval = 15) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            usleep(200_000)
        }
        return false
    }

    func testPaintAndUndo() {
        paintStroke()
        showHistory()
        let step = app.staticTexts["Brush Stroke"].firstMatch
        XCTAssertTrue(step.waitForExistence(timeout: 5), "the stroke isn't in the history")
        app.typeKey("z", modifierFlags: .command)
        // After undo the step stays listed (as redoable) and Redo is available.
        app.menuBars.menuBarItems["Edit"].click()
        XCTAssertTrue(app.menuItems["Redo Brush Stroke"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.menuItems["Redo Brush Stroke"].firstMatch.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testSaveDocument() {
        paintStroke()
        app.typeKey("s", modifierFlags: .command)
        save(as: "UITest", in: outDir)
        XCTAssertTrue(waitForFile(outDir.appending(path: "UITest.glimmer")), "the document wasn't saved")
    }

    func testExportPNG() {
        paintStroke()
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Export…"].firstMatch.click()
        let export = app.buttons["Export…"].firstMatch
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        export.click()
        save(as: "UITest.png", in: outDir)
        let file = outDir.appending(path: "UITest.png")
        XCTAssertTrue(waitForFile(file), "nothing was exported")
        let data = try? Data(contentsOf: file)
        XCTAssertEqual(data?.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
    }
}
