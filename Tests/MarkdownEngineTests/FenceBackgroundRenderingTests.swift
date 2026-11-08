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

    private func makeEditor(_ text: String, rendersMarkdownFences: Bool = false, railWidth: CGFloat = 10) throws
        -> (coordinator: NativeTextViewCoordinator, view: NativeTextView) {
        _ = NSApplication.shared
        let coordinator = NativeTextViewCoordinator(
            text: .constant(text), fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        coordinator.configuration.services.syntaxHighlighter = TestSyntaxHighlighter()
        coordinator.configuration.renderMarkdownCodeFences = rendersMarkdownFences
        coordinator.configuration.codeBlock.markdownFenceRailWidth = railWidth
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
        let outer = try #require(fills.first { $0.railColors.isEmpty })
        let middle = try #require(fills.first { $0.railColors.count == 1 })
        #expect(deepest.railColors == [outer.color, middle.color])
        #expect(deepest.rect.minX == 0)
        #expect(deepest.rect.width == 300)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
        let y = Int(deepest.rect.midY * scale)
        for (x, expected) in [(5, outer.color), (15, middle.color), (290, deepest.color)] {
            let column = Int(CGFloat(x) * scale)
            let actual = try #require(bitmap.colorAt(x: column, y: y)?.usingColorSpace(.deviceRGB))
            let rgb = try #require(expected.usingColorSpace(.deviceRGB))
            #expect(abs(actual.redComponent - rgb.redComponent) < 0.02)
            #expect(abs(actual.greenComponent - rgb.greenComponent) < 0.02)
            #expect(abs(actual.blueComponent - rgb.blueComponent) < 0.02)
            #expect(actual.alphaComponent > 0.98)
        }
    }

    @Test("Restyling preserves a custom fence indent without accumulating it")
    func repeatedRestyling() throws {
        let text = "````markdown\nOuter\n```markdown\nInner\n```\n````\n"
        let editor = try makeEditor(text, rendersMarkdownFences: true, railWidth: 17)
        let location = (text as NSString).range(of: "Inner").location
        let range = (text as NSString).paragraphRange(for: NSRange(location: location, length: 0))
        for _ in 0..<3 {
            editor.coordinator.restyleParagraphs([range], in: editor.view)
            let style = editor.view.textStorage?.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
            #expect(style?.firstLineHeadIndent == 17)
        }
    }

    @Test("Delimiter edits match a fresh parse and fresh fence layout")
    func delimiterEditEquivalence() throws {
        let text = "Before\n`````markdown\nOuter\n````markdown\nMiddle\n```markdown\n# Inner\n- item\n```\n````\n`````\nAfter\n"
        let editor = try makeEditor(text, rendersMarkdownFences: true)
        let edits = [("```markdown\n# Inner", "```swift\n# Inner"),
                     ("```swift\n# Inner", "```markdown\n# Inner"),
                     ("\n```\n````\n", "\n``\n````\n"),
                     ("\n``\n````\n", "\n```\n````\n"),
                     ("`````markdown", "``````markdown"),
                     ("``````markdown", "`````markdown")]
        for (needle, replacement) in edits {
            let range = (editor.view.string as NSString).range(of: needle)
            #expect(range.location != NSNotFound)
            editor.view.setSelectedRange(range)
            editor.view.insertText(replacement, replacementRange: range)
            editor.view.setSelectedRange(NSRange(location: 0, length: 0))
            let fresh = try makeEditor(editor.view.string, rendersMarkdownFences: true)
            fresh.view.setSelectedRange(NSRange(location: 0, length: 0))
            let actual = editor.coordinator.parsedDocument(for: editor.view.string).tokens
            let expected = fresh.coordinator.parsedDocument(for: fresh.view.string).tokens
            #expect(actual.count == expected.count)
            for (a, b) in zip(actual, expected) {
                #expect(a.kind == b.kind && a.range == b.range && a.contentRange == b.contentRange && a.markerRanges == b.markerRanges)
            }
            let storage = try #require(editor.view.textStorage)
            let reference = try #require(fresh.view.textStorage)
            for index in 0..<storage.length {
                #expect(storage.attribute(.markdownFenceDepth, at: index, effectiveRange: nil) as? Int
                    == reference.attribute(.markdownFenceDepth, at: index, effectiveRange: nil) as? Int)
                let a = storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
                let b = reference.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
                #expect(a?.firstLineHeadIndent == b?.firstLineHeadIndent)
                #expect(a?.headIndent == b?.headIndent)
            }
        }
    }

}
