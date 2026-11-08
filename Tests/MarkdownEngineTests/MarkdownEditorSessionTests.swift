import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@Suite(.serialized) @MainActor
struct MarkdownEditorSessionTests {
    private func editor(_ text: String) -> (NativeTextView, NativeTextViewCoordinator, MarkdownEditorSession) {
        _ = NSApplication.shared
        let wrapper = NativeTextViewWrapper(text: .constant(text))
        let coordinator = wrapper.makeCoordinator()
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.isEditable = true
        view.allowsUndo = true
        view.delegate = coordinator
        coordinator.textView = view
        coordinator.rebuildTextStorageAndStyle(view, from: text)
        coordinator.lastSyncedText = text
        coordinator.lastComputedStorage = text
        coordinator.previousDisplayLength = text.utf16.count
        let session = MarkdownEditorSession()
        session.coordinator = coordinator
        return (view, coordinator, session)
    }

    @Test func reviewUndoThenEarlierTypingAndRedo() throws {
        let (view, coordinator, session) = editor("Hello")
        defer { withExtendedLifetime(coordinator) {} }
        let undo = try #require(view.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        view.insertText(" world", replacementRange: NSRange(location: 5, length: 0))
        undo.endUndoGrouping()
        view.breakUndoCoalescing()
        view.isEditable = false // parked while reviewing
        #expect(session.apply("Hello reviewed world", replacing: "Hello world"))
        #expect(!view.isEditable)
        view.isEditable = true
        undo.undo()
        #expect(view.string == "Hello world")
        undo.undo()
        #expect(view.string == "Hello")
        undo.redo()
        #expect(view.string == "Hello world")
        undo.redo()
        #expect(view.string == "Hello reviewed world")
    }

    @Test func rejectsStaleReviewAndNoOpAddsNoUndo() throws {
        let (view, coordinator, session) = editor("Hello")
        defer { withExtendedLifetime(coordinator) {} }
        #expect(!session.apply("Wrong", replacing: "Old"))
        #expect(view.string == "Hello")
        #expect(session.apply("Hello", replacing: "Hello"))
        #expect(view.undoManager?.canUndo == false)
    }

    @Test func preservesWikiLinkIDsAcrossReviewUndo() throws {
        let (view, coordinator, session) = editor("Hello [[Page|id-one]]")
        defer { withExtendedLifetime(coordinator) {} }
        let undo = try #require(view.undoManager)
        undo.groupsByEvent = false
        #expect(session.apply("Hello [[Other|id-two]]", replacing: "Hello [[Page|id-one]]"))
        let updated = WikiLinkService.makeStorageState(from: view.string,
            existingMetadata: coordinator.wikiLinkMetadata, textStorage: view.textStorage).storage
        #expect(updated == "Hello [[Other|id-two]]")
        undo.undo()
        let original = WikiLinkService.makeStorageState(from: view.string,
            existingMetadata: coordinator.wikiLinkMetadata, textStorage: view.textStorage).storage
        #expect(original == "Hello [[Page|id-one]]")
    }
    @Test func canAddAndRemoveWikiIDsWithoutReusingStaleMetadata() throws {
        for (before, after) in [("[[Page|id]]", "[[Page]]"), ("[[Page]]", "[[Page|id]]")] {
            let (view, coordinator, session) = editor(before)
            defer { withExtendedLifetime(coordinator) {} }
            let undo = try #require(view.undoManager)
            undo.groupsByEvent = false
            #expect(session.apply(after, replacing: before))
            #expect(WikiLinkService.makeStorageState(from: view.string,
                existingMetadata: coordinator.wikiLinkMetadata, textStorage: view.textStorage).storage == after)
            undo.undo()
            #expect(WikiLinkService.makeStorageState(from: view.string,
                existingMetadata: coordinator.wikiLinkMetadata, textStorage: view.textStorage).storage == before)
        }
    }

    @Test func appliesExactMultilineMarkdown() {
        let (view, coordinator, session) = editor("Before")
        defer { withExtendedLifetime(coordinator) {} }
        let source = "# Heading\r\n\r\n- item 👨‍👩‍👧‍👦\r\n\r\n````markdown\r\n**bold**\r\n````\r\n"
        #expect(session.apply(source, replacing: "Before"))
        #expect(view.string == source)
    }

}
