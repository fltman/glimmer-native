import Foundation
@testable import GlimmerCore
import Testing

/// Three agent changes in a row are three undo steps (Jämmer found the merge first).
@MainActor @Suite struct UndoStepTests {
    @MainActor final class Doc {
        var layers: [String] = []
        func add(_ name: String, _ undo: UndoManager, separate: Bool) {
            let register = { self.set(self.layers + [name], undo) }
            if separate { undo.separateStep(register) } else { register() }
        }
        /// Like GlimmerDocument: a step restores the earlier state and registers the opposite.
        func set(_ new: [String], _ undo: UndoManager) {
            let old = layers
            layers = new
            undo.registerUndo(withTarget: self) { doc in doc.set(old, undo) }
        }
    }

    @Test func automaticGroupingMergesChangesWithoutEvents() {
        // No run loop turns between the changes, like back-to-back API requests.
        let undo = UndoManager(), doc = Doc()
        for name in ["a", "b", "c"] { doc.add(name, undo, separate: false) }
        undo.undo()
        #expect(doc.layers.isEmpty, "the bug: one undo took all three back")
    }

    @Test func separateStepsUndoOneAtATime() {
        let undo = UndoManager(), doc = Doc()
        for name in ["a", "b", "c"] { doc.add(name, undo, separate: true) }
        undo.undo()
        undo.undo()
        #expect(doc.layers == ["a"])
        undo.redo()
        #expect(doc.layers == ["a", "b"])
    }

    @Test func stepsStaySeparateAcrossUndoAndRedo() {
        let undo = UndoManager(), doc = Doc()
        doc.add("a", undo, separate: true)
        doc.add("b", undo, separate: true)
        undo.undo()
        doc.add("c", undo, separate: true)  // a new step after an undo drops the redo
        #expect(doc.layers == ["a", "c"] && !undo.canRedo)
        undo.undo()
        undo.undo()
        #expect(doc.layers.isEmpty)
        undo.redo()
        #expect(doc.layers == ["a"])
        #expect(undo.groupsByEvent, "automatic grouping is back on for the user's own edits")
    }
}
