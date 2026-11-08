import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Fence backgrounds under text")
struct FenceBackgroundRenderingTests {
    private struct TestSyntaxHighlighter: SyntaxHighlighter {
        func codeFont(size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
        func backgroundColor() -> NSColor { .systemRed }
        func highlight(code: String, language: String?) -> NSAttributedString? { nil }
        var appearanceDidChangeNotification: Notification.Name? { nil }
    }

    private func makeEditor(_ text: String, rendersMarkdownFences: Bool = false) throws
        -> (coordinator: NativeTextViewCoordinator, view: NativeTextView) {
        _ = NSApplication.shared
        let coordinator = NativeTextViewCoordinator(
            text: .constant(text), fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        coordinator.configuration.services.syntaxHighlighter = TestSyntaxHighlighter()
        coordinator.configuration.renderMarkdownCodeFences = rendersMarkdownFences
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        view.configuration = coordinator.configuration
        view.backgroundColor = .clear
        view.drawsBackground = true
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.size = NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
        view.delegate = coordinator
        let tlm = try #require(view.textLayoutManager)
        let layoutDelegate = MarkdownLayoutManagerDelegate()
        coordinator.layoutDelegate = layoutDelegate
        tlm.delegate = layoutDelegate
        let bridge = LayoutBridge(tlm)
        view.layoutBridge = bridge
        coordinator.layoutBridge = bridge
        coordinator.textView = view
        coordinator.rebuildTextStorageAndStyle(view, from: text)
        tlm.ensureLayout(for: tlm.documentRange)
        return (coordinator, view)
    }

    @Test("the text view background pass paints full-width fence color")
    func fullWidthBackgroundPass() throws {
        let editor = try makeEditor("Before\n```swift\nlet x = 1\n```\nAfter\n")
        let view = editor.view
        let fills = view.fenceBackgrounds(in: view.bounds)
        let fill = try #require(fills.first)
        #expect(fill.rect.width == 300)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let x = bitmap.pixelsWide - 20
        let solidPixels = (0..<bitmap.pixelsHigh).filter {
            (bitmap.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > 0.8
        }
        #expect(!solidPixels.isEmpty, "The full-width fill must appear in the text view's display")
    }

    @Test("nested rails are supplied by the same background pass")
    func nestedRailBackgroundPass() throws {
        let text = """
        `````markdown
        Outer
        ````markdown
        Middle
        ```markdown
        Inner
        ```
        ````
        `````
        """
        let editor = try makeEditor(text, rendersMarkdownFences: true)
        let view = editor.view
        let fills = view.fenceBackgrounds(in: view.bounds)
        #expect(fills.contains { $0.railColors.count == 0 })
        #expect(fills.contains { $0.railColors.count == 1 })
        let deepest = try #require(fills.first { $0.railColors.count == 2 })
        #expect(deepest.rect.minX == 0)
        #expect(deepest.rect.width == 300)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
        let y = Int(deepest.rect.midY * scale)
        let topY = bitmap.pixelsHigh - y - 1
        for x in [5, 15, 290] {
            let column = Int(CGFloat(x) * scale)
            let alpha = max(bitmap.colorAt(x: column, y: y)?.alphaComponent ?? 0,
                            bitmap.colorAt(x: column, y: topY)?.alphaComponent ?? 0)
            #expect(alpha > 0.8, "The inner fence and both rails should render under text")
        }
    }

}
