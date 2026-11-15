import Foundation

extension UndoManager {
    /// Registers what `register` adds as one undo step of its own.
    ///
    /// With `groupsByEvent` (the default), the undo manager opens a group on the first
    /// registration and closes it only after a user event. Changes made by the agent API, or
    /// by work that finishes after its event (an assistant plan), aren't events: several of
    /// them landed in one open group, and one Undo took them all back. So such a change gets
    /// an explicit group with automatic grouping off, and never opens an automatic one. Every
    /// change made outside an event must come through here. (Closing a leftover automatic group
    /// by hand doesn't work: the next undo() closes it again and throws.) Never while undoing
    /// or redoing, when the manager builds the opposite step itself.
    public func separateStep(_ register: () -> Void) {
        guard !isUndoing, !isRedoing else {
            register()
            return
        }
        let automatic = groupsByEvent
        // An explicit group opened while groupsByEvent is on is taken for the automatic one,
        // and the next undo() closes it a second time (an NSInternalInconsistencyException).
        groupsByEvent = false
        beginUndoGrouping()
        register()
        endUndoGrouping()
        groupsByEvent = automatic
    }
}
