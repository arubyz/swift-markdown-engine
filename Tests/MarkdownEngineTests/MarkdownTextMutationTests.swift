//
//  MarkdownTextMutationTests.swift
//  MarkdownEngineTests
//
//  Exact native edit descriptors for embedders that maintain their own
//  source authority or mirror an edit into another presentation.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Markdown text mutation callback")
struct MarkdownTextMutationTests {

    private func makeEditor(
        _ text: String,
        onTextMutation: @escaping (MarkdownTextMutation) -> Void
    ) -> NativeTextView {
        _ = NSApplication.shared
        let wrapper = NativeTextViewWrapper(
            text: .constant(text),
            fontName: "SF Pro",
            fontSize: 16,
            onTextMutation: onTextMutation
        )
        let coordinator = wrapper.makeCoordinator()
        let textView = NativeTextView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400)
        )
        textView.isEditable = true
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.rebuildTextStorageAndStyle(textView, from: text)
        coordinator.lastSyncedText = text
        coordinator.lastComputedStorage = text
        coordinator.previousDisplayLength = (text as NSString).length
        return textView
    }

    @Test("reports the exact accepted UTF-16 replacement")
    func reportsExactAcceptedReplacement() {
        var received: [MarkdownTextMutation] = []
        let textView = makeEditor("- [x] **fast** item") {
            received.append($0)
        }

        textView.insertText(
            "0",
            replacementRange: NSRange(location: 12, length: 0)
        )

        #expect(textView.string == "- [x] **fast0** item")
        #expect(
            received == [
                MarkdownTextMutation(
                    range: NSRange(location: 12, length: 0),
                    replacement: "0"
                )
            ]
        )
    }

    @Test("a proposed edit alone emits no completed mutation")
    func proposedEditDoesNotEmitMutation() throws {
        var received: [MarkdownTextMutation] = []
        let textView = makeEditor("alpha") {
            received.append($0)
        }
        let coordinator = try #require(
            textView.delegate as? NativeTextViewCoordinator
        )

        #expect(
            coordinator.textView(
                textView,
                shouldChangeTextIn: NSRange(location: 5, length: 0),
                replacementString: "x"
            )
        )
        #expect(received.isEmpty)
    }

    /// AppKit proposes attribute-only changes with a nil replacement string —
    /// data detection linkifying a phone number, Format > Font. No text moves, so
    /// a listener mirroring these must not be told the range was replaced.
    @Test("an attribute-only change emits no mutation")
    func attributeOnlyChangeEmitsNoMutation() {
        var received: [MarkdownTextMutation] = []
        let text = "call 555 1234 now"
        let textView = makeEditor(text) { received.append($0) }
        textView.allowsUndo = true

        let affected = NSRange(location: 5, length: 8)   // "555 1234"
        #expect(textView.shouldChangeText(in: affected, replacementString: nil))
        textView.textStorage?.addAttribute(.link, value: URL(string: "tel:5551234")!, range: affected)
        textView.didChangeText()

        #expect(textView.string == text)
        #expect(received.isEmpty)
        #expect(textView.undoManager?.canUndo == false,
                "Derived attributes must not create a source undo entry")
    }

    @Test("attribute-only validation preserves undo registration and real text undo")
    func attributeUndoSuppressionIsScoped() throws {
        let textView = makeEditor("call 555 1234 now") { _ in }
        textView.allowsUndo = true
        let manager = try #require(textView.undoManager)
        manager.groupsByEvent = false
        let range = NSRange(location: 5, length: 8)

        manager.disableUndoRegistration()
        #expect(textView.shouldChangeText(in: range, replacementString: nil))
        #expect(!manager.isUndoRegistrationEnabled)
        manager.enableUndoRegistration()
        #expect(textView.shouldChangeText(in: range, replacementString: nil))
        #expect(manager.isUndoRegistrationEnabled)
        #expect(!manager.canUndo)

        // Character replacements, including automatic corrections, still use
        // the same native validation path and must remain undoable.
        manager.beginUndoGrouping()
        #expect(textView.shouldChangeText(in: range, replacementString: "555 5678"))
        textView.textStorage?.replaceCharacters(in: range, with: "555 5678")
        textView.didChangeText()
        manager.endUndoGrouping()
        #expect(textView.string == "call 555 5678 now")
        manager.undo()
        #expect(textView.string == "call 555 1234 now")
        manager.redo()
        #expect(textView.string == "call 555 5678 now")
    }

}
