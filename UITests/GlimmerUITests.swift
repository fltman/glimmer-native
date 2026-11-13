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
        app.launchArguments = ["-skipWelcome", "-uiTestingNewDocument"]
        app.launch()
        XCTAssertTrue(canvas.waitForExistence(timeout: 15), "no document window")
        // Clicks go to whatever is on top: make sure that's Glimmer.
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "Glimmer didn't come to the front")
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    /// The frontmost document window.
    private var window: XCUIElement { app.windows.element(boundBy: 0) }
    private var canvas: XCUIElement { window.images["canvas"].firstMatch }

    /// One brush dab. (XCUITest's press-and-drag doesn't reach the canvas as
    /// mouse events; clicks do, and a click is a one-dab stroke.)
    private func paintStroke() {
        window.buttons["Brush"].firstMatch.click()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).click()
    }

    private func showHistory() {
        // History lives in the floating panel behind the Layers chip.
        let tab = window.radioButtons["History"].firstMatch
        if !tab.exists { window.buttons["Layers"].firstMatch.click() }
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "the Layers panel didn't open")
        tab.click()
    }

    /// Points the open/save panel at `directory`; for a save panel, also names the file.
    private func choose(_ file: String, saving: Bool) {
        // Sandboxed apps get the panel as its own window ("save-panel"/"open-panel").
        let candidates = [app.windows["save-panel"], app.windows["open-panel"], app.sheets.firstMatch, app.dialogs.firstMatch]
        let deadline = Date().addingTimeInterval(8)
        var found: XCUIElement?
        while found == nil, Date() < deadline {
            found = candidates.first { $0.exists }
            if found == nil { usleep(250_000) }
        }
        guard let panel = found else {
            attachState("no file panel")
            XCTFail("no file panel")
            return
        }
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

    /// The window's own screenshot plus the accessibility tree, for diagnosing failures.
    private func attachState(_ name: String) {
        let shot = XCTAttachment(screenshot: window.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + " (tree)"
        tree.lifetime = .keepAlways
        add(tree)
    }

    func testPaintAndUndo() {
        paintStroke()
        showHistory()
        // History rows: "Open" plus one per step.
        let rows = window.outlineRows
        let deadline = Date().addingTimeInterval(5)
        while rows.count < 2, Date() < deadline { usleep(200_000) }
        if rows.count < 2 { attachState("after stroke") }
        XCTAssertEqual(rows.count, 2, "the stroke isn't in the history")
        let edit = app.menuBars.menuBarItems["Edit"]
        edit.click()
        let undo = app.menuItems["Undo Brush Stroke"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 3), "no Undo Brush Stroke")
        undo.click()
        edit.click()
        let redo = app.menuItems["Redo Brush Stroke"].firstMatch
        XCTAssertTrue(redo.waitForExistence(timeout: 3), "no Redo Brush Stroke")
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
