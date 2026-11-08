import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite(.serialized)
struct ReviewUndoHistoryTests {
    @MainActor private final class Document: ObservableObject {
        @Published var text = """
        # Markdown

        See https://example.com and contact jason@example.com.

        1. Ordered lists renumber as you edit
        2. and auto-continue too

        ## Task lists

        - [ ] Ship it

        ## Tables

        Cells wrap to the available width:

        | Novel | Opening line |
        |---|---|
        | Der Zauberberg (1924) | At noon on November 9, 2026. |
        | Book (1966–67) | Call 415-555-1234. |

        End of document.
        """
        @Published var reviewing = false
        let session = MarkdownEditorSession()
    }
    private struct Host: View {
        @ObservedObject var document: Document
        var body: some View {
            NativeTextViewWrapper(text: $document.text, isEditable: !document.reviewing,
                                  editorSession: document.session)
        }
    }
    private static var windows: [NSWindow] = []
    private static func spin(_ seconds: TimeInterval) async {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            pump()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    private static func pump() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }

    @Test(arguments: [0, 1, 3])
    func reviewHasExactlyOneUndoBetweenTypingEdits(annotationCount: Int) async throws {
        _ = NSApplication.shared
        let document = Document()
        let original = document.text
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Host(document: document))
        window.makeKeyAndOrderFront(nil)
        Self.windows.append(window)
        await Self.spin(0.4)
        let coordinator = try #require(document.session.coordinator)
        let view = try #require(coordinator.textView)
        let undo = try #require(view.undoManager)
        window.makeFirstResponder(view)
        #expect(undo.groupsByEvent)
        defer { window.orderOut(nil) }

        view.setSelectedRange((view.string as NSString).range(of: "continue"))
        view.deleteBackward(nil)
        view.moveDown(nil)
        await Self.spin(0.3)
        let beforeReview = view.string
        document.reviewing = true
        window.makeFirstResponder(nil)
        await Self.spin(0.2)
        let reviewed = beforeReview.replacingOccurrences(of: "Ship it", with: "Ship it after reviewing the changes")
        #expect(document.session.apply(reviewed, replacing: beforeReview))
        document.reviewing = false
        await Self.spin(0.05)
        window.makeFirstResponder(view)
        await Self.spin(1.5)
        // Deliver the attribute-only transaction used by AppKit data detection
        // after the review's event has finished. Calling the mutation directly
        // avoids relying on system detector preferences or service timing.
        for _ in 0..<annotationCount {
            let phone = (view.string as NSString).range(of: "415-555-1234")
            #expect(view.shouldChangeText(in: phone, replacementString: nil))
            view.textStorage?.addAttribute(.link, value: URL(string: "tel:4155551234")!, range: phone)
            view.didChangeText()
            await Self.spin(0.1)
        }
        view.setSelectedRange((view.string as NSString).range(of: "available"))
        view.deleteBackward(nil)
        view.moveDown(nil)
        await Self.spin(1.5)

        for (index, expected) in [reviewed, beforeReview, original].enumerated() {
            undo.undo()
            await Self.spin(0.2)
            #expect(view.string == expected, "Undo step \(index + 1) must change source, not only attributes")

        }
        #expect(!undo.canUndo, "No attribute-only undo entries may remain before the first edit")
        for expected in [beforeReview, reviewed, reviewed.replacingOccurrences(of: "available", with: "")] {
            undo.redo()
            await Self.spin(0.2)
            #expect(view.string == expected)
        }
        #expect(!undo.canRedo)
    }
}
