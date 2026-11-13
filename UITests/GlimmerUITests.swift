import XCTest

/// The critical flows end to end: new document, paint, undo, save, export.
/// Run with `scripts/uitest.sh` (drives the real app: keep hands off the mouse).
///
/// The test runner is sandboxed and can't read what the app writes, so results
/// are checked through the app: a saved document's window takes the file name,
/// and an exported PNG is opened again.
final class GlimmerUITests: XCTestCase {
    private var app: XCUIApplication!
    /// The app writes here through the save panel (user-selected, so allowed in its sandbox).
    private let directory = "/private/tmp"
    private let fileName = "GlimmerUITest-\(UUID().uuidString.prefix(8))"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-skipWelcome", "-ApplePersistenceIgnoreState", "YES", "-uiTestingNewDocument"]
        app.launch()
        XCTAssertTrue(canvas.waitForExistence(timeout: 15), "no document window")
    }

    override func tearDownWithError() throws {
        app?.terminate()
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

    /// Points the open/save panel at `directory`; for a save panel, also names the file.
    private func choose(_ file: String, saving: Bool) {
        let panel = app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.dialogs.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "no file panel")
        if saving {
            let nameField = panel.textFields.firstMatch
            nameField.click()
            nameField.typeKey("a", modifierFlags: .command)
            nameField.typeText(file)
            app.typeKey("g", modifierFlags: [.command, .shift])
            app.typeText(directory + "\n")
        } else {
            app.typeKey("g", modifierFlags: [.command, .shift])
            app.typeText(directory + "/" + file + "\n")
        }
        sleep(1)
        app.typeKey(.return, modifierFlags: [])
    }

    func testPaintAndUndo() {
        paintStroke()
        showHistory()
        XCTAssertTrue(app.staticTexts["Brush Stroke"].firstMatch.waitForExistence(timeout: 5), "the stroke isn't in the history")
        app.typeKey("z", modifierFlags: .command)
        app.menuBars.menuBarItems["Edit"].click()
        let redo = app.menuItems["Redo Brush Stroke"].firstMatch
        XCTAssertTrue(redo.waitForExistence(timeout: 3))
        XCTAssertTrue(redo.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testSaveDocument() {
        paintStroke()
        app.typeKey("s", modifierFlags: .command)
        choose(fileName, saving: true)
        XCTAssertTrue(app.windows[fileName].firstMatch.waitForExistence(timeout: 10)
                      || app.windows["\(fileName).glimmer"].firstMatch.waitForExistence(timeout: 2),
                      "the window didn't take the saved name")
    }

    func testExportPNGAndReopen() {
        paintStroke()
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Export…"].firstMatch.click()
        let export = app.buttons["Export…"].firstMatch
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        export.click()
        choose("\(fileName).png", saving: true)
        sleep(2)
        // Open the exported file: it becomes a new 800 × 600 document.
        let windows = app.windows.count
        app.typeKey("o", modifierFlags: .command)
        choose("\(fileName).png", saving: false)
        let deadline = Date().addingTimeInterval(10)
        while app.windows.count <= windows, Date() < deadline { usleep(250_000) }
        XCTAssertGreaterThan(app.windows.count, windows, "the exported PNG didn't open")
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        XCTAssertTrue((canvas.value as? String)?.contains("800") == true, "\(canvas.value ?? "")")
    }
}
