import AppKit

extension NativeTextView {
    /// Markdown source owns the document's formatting. AppKit can asynchronously
    /// propose attribute-only edits (for example, data detection adding a link)
    /// after an insertion. Registering those on the native undo stack produces
    /// invisible undo steps between actual source edits.
    ///
    /// Suppress registration only while AppKit validates/registers an attribute
    /// edit. The attributes still apply, and character edits—including automatic
    /// corrections and review application—retain normal native undo behavior.
    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        guard replacementStrings == nil,
              let manager = undoManager, manager.isUndoRegistrationEnabled else {
            return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        }
        manager.disableUndoRegistration()
        defer { manager.enableUndoRegistration() }
        return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
    }
}
