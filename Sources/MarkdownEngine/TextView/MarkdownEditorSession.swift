import AppKit

/// Optional host handle for applying a reviewed revision through native undo.
/// Keep the wrapper mounted, with the same documentId, throughout review.
@MainActor
public final class MarkdownEditorSession {
    weak var coordinator: NativeTextViewCoordinator?
    public init() {}

    /// Refuses stale reviews. This uses NSTextView's native edit path, so one
    /// undo restores the pre-review text and earlier typing remains undoable.
    @discardableResult
    public func apply(_ source: String, replacing expectedSource: String,
                      actionName: String = "Review Markdown Changes") -> Bool {
        guard let coordinator, let view = coordinator.textView else { return false }
        let current = coordinator.configuration.rawSourceMode ? view.string :
            WikiLinkService.makeStorageState(from: view.string,
                existingMetadata: coordinator.wikiLinkMetadata, textStorage: view.textStorage).storage
        guard current.utf8.elementsEqual(expectedSource.utf8) else { return false }
        guard !source.utf8.elementsEqual(current.utf8) else { return true }
        let replacement: NSMutableAttributedString
        if coordinator.configuration.rawSourceMode {
            replacement = NSMutableAttributedString(string: source)
        } else {
            let state = WikiLinkService.makeDisplayState(from: source)
            replacement = NSMutableAttributedString(string: state.display)
            for (range, metadata) in state.metadata {
                // Empty is an explicit absence; nil would fall back to the
                // previous document's range-keyed metadata at this position.
                replacement.addAttribute(.wikiLinkID, value: metadata.id ?? "",
                    range: NSRange(location: range.location, length: range.length))
            }
        }
        // Preserve an explicit no-ID marker in the native undo payload too,
        // so undoing an added ID cannot inherit the reviewed version's ID.
        if !coordinator.configuration.rawSourceMode {
            let previous = WikiLinkService.makeDisplayState(from: current)
            for (range, metadata) in previous.metadata where metadata.id == nil {
                view.textStorage?.addAttribute(.wikiLinkID, value: "",
                    range: NSRange(location: range.location, length: range.length))
            }
        }
        let editable = view.isEditable
        view.isEditable = true
        view.breakUndoCoalescing()
        view.undoManager?.beginUndoGrouping()
        view.insertText(replacement, replacementRange: NSRange(location: 0, length: (view.string as NSString).length))
        view.undoManager?.setActionName(actionName)
        view.undoManager?.endUndoGrouping()
        view.breakUndoCoalescing()
        view.isEditable = editable
        return view.string.utf8.elementsEqual(replacement.string.utf8)
    }
}
