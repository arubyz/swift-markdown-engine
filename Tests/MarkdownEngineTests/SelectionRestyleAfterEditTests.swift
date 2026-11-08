import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite(.serialized)
struct SelectionRestyleAfterEditTests {
    private let source = """
    Text above the list.

    A separate paragraph.

    ## Tasks

    - [ ] Ship it
    - [x] Already done

    Text below the list.
    """

    private func editor() -> (NativeTextView, NativeTextViewCoordinator) {
        _ = NSApplication.shared
        let coordinator = NativeTextViewWrapper(text: .constant(source)).makeCoordinator()
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.isEditable = true
        view.allowsUndo = true
        view.delegate = coordinator
        coordinator.textView = view
        coordinator.rebuildTextStorageAndStyle(view, from: source)
        view.setSelectedRange(NSRange(location: 2, length: 0))
        return (view, coordinator)
    }

    private func expectCheckboxes(_ view: NSTextView, revealed: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
        for marker in ["[ ]", "[x]"] {
            let range = (view.string as NSString).range(of: marker)
            let value = view.textStorage?.attribute(.taskCheckbox, at: range.location, effectiveRange: nil)
            #expect((value == nil) == revealed, "Checkbox \(marker) must follow the current selection", sourceLocation: sourceLocation)
        }
    }

    @Test("text change preserves the full selection used to reveal task syntax")
    func leavingSelectionAfterTextChange() {
        let (view, coordinator) = editor()
        let selection = NSRange(location: 0, length: view.string.utf16.count)
        view.setSelectedRange(selection)
        expectCheckboxes(view, revealed: true)
        // Undo can report a restored selection before its completed text-change
        // notification. The subsequent deselection must still know that span.
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        #expect(coordinator.previousSelectedRange == selection)
        view.setSelectedRange(NSRange(location: 2, length: 0))
        expectCheckboxes(view, revealed: false)
    }

    @Test("a mid-edit selection change re-hides syntax outside the edited paragraphs")
    func selectionChangesDuringEdit() {
        let (view, coordinator) = editor()
        defer { withExtendedLifetime(coordinator) {} }
        view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
        expectCheckboxes(view, revealed: true)
        let editRange = (view.string as NSString).range(of: "above")
        #expect(view.shouldChangeText(in: editRange, replacementString: "before"))
        view.textStorage?.replaceCharacters(in: editRange, with: "before")
        // AppKit reports selection changes inside a native edit. Its selection
        // handler deliberately defers styling until didChangeText.
        view.setSelectedRange(NSRange(location: editRange.location + 6, length: 0))
        view.didChangeText()
        expectCheckboxes(view, revealed: false)
        #expect(view.string == source.replacingOccurrences(of: "above", with: "before"))
    }
}
