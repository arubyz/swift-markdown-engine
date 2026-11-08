import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Embedded Markdown fences")
struct EmbeddedMarkdownFenceTests {
    private struct TestImageProvider: EmbeddedImageProvider {
        func image(for reference: EmbeddedImageRequest) -> NSImage? {
            NSImage(size: NSSize(width: 600, height: 40))
        }
        func fingerprint() -> AnyHashable { "nested-fence-image-width" }
    }

    private struct TestLatexRenderer: LatexRenderer {
        func render(latex: String, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult? {
            let size = NSSize(width: 40, height: 20)
            return LatexRenderResult(image: NSImage(size: size), size: size, baselineOffset: 0)
        }
    }

    private func coordinator(_ text: String, enabled: Bool) -> NativeTextViewCoordinator {
        let coordinator = NativeTextViewCoordinator(
            text: .constant(text), fontName: "SF Pro", fontSize: 16,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        coordinator.configuration.renderMarkdownCodeFences = enabled
        return coordinator
    }

    @Test("Opt-in body tokens enable Markdown input without changing ordinary code fences")
    func bodyClassification() {
        let text = "```markdown\n# Title\n- item\n```\n\n```swift\n# literal\n```\n"
        let enabled = coordinator(text, enabled: true).parsedDocument(for: text)
        let bodyStart = (text as NSString).range(of: "# Title").location
        let normalCode = (text as NSString).range(of: "# literal").location
        #expect(enabled.tokens.contains { $0.kind == .heading && $0.range.location == bodyStart })
        #expect(!MarkdownDetection.isInsideCodeBlock(location: bodyStart, codeTokens: enabled.codeTokens))
        #expect(MarkdownDetection.isInsideCodeBlock(location: normalCode, codeTokens: enabled.codeTokens))

        let disabled = coordinator(text, enabled: false).parsedDocument(for: text)
        #expect(!disabled.tokens.contains { $0.kind == .heading && $0.range.location == bodyStart })
        #expect(MarkdownDetection.isInsideCodeBlock(location: bodyStart, codeTokens: disabled.codeTokens))
    }

    @Test("Four-backtick and case-varied Markdown tags retain source ranges")
    func longerFence() {
        let text = "```` MARKDOWN\n# Title\n````\n"
        let parsed = coordinator(text, enabled: true).parsedDocument(for: text)
        let heading = (text as NSString).range(of: "# Title").location
        #expect(parsed.tokens.contains { $0.kind == .heading && $0.range.location == heading })
        #expect(!MarkdownDetection.isInsideCodeBlock(location: heading, codeTokens: parsed.codeTokens))
    }

    @Test("Markdown fence bodies expand recursively through several marker lengths")
    func nestedFences() {
        let text = """
        `````markdown
        # Outer
        ````markdown
        # Middle
        ```markdown
        # Inner
        ```
        ````
        `````

        """
        let ns = text as NSString
        let parsed = coordinator(text, enabled: true).parsedDocument(for: text)
        for title in ["# Outer", "# Middle", "# Inner"] {
            let location = ns.range(of: title).location
            #expect(parsed.tokens.contains { $0.kind == .heading && $0.range.location == location })
            #expect(!MarkdownDetection.isInsideCodeBlock(location: location, codeTokens: parsed.codeTokens))
        }
        let fences = parsed.tokens.filter { $0.kind == .codeBlock }
        #expect(fences.count == 3)
        #expect(fences.map { $0.markerRanges.last?.length } == [5, 4, 3])
    }

    @Test("Nested Markdown fences expose table, image, and math tokens")
    func nestedRichContentTokens() {
        _ = NSApplication.shared
        let text = """
        ````markdown
        ```markdown
        | ColumnIdentifierOneCannotBreak | ColumnIdentifierTwoCannotBreak |
        |---|---|
        | FirstIdentifierCannotBreak | SecondIdentifierCannotBreak |

        ![[sample]]
        ![alt](sample.png)
        $x^2$

        $$
        x^2
        $$
        ```
        ````

        """
        let parsed = coordinator(text, enabled: true).parsedDocument(for: text)
        for kind in [MarkdownTokenKind.table, .imageEmbed, .imageLink, .inlineLatex, .blockLatex] {
            #expect(parsed.tokens.contains { $0.kind == kind }, "Missing \(kind) in nested Markdown fence")
        }
        var config = MarkdownEditorConfiguration.default
        config.renderMarkdownCodeFences = true
        config.services.images = TestImageProvider()
        config.services.latex = TestLatexRenderer()
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 500))
        view.textContainer?.size = NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.lineFragmentPadding = 0
        let bridge = view.textLayoutManager.map(LayoutBridge.init)
        let styled = MarkdownStyler.styleAttributes(
            text: text, fontName: "SF Pro", fontSize: 16,
            layoutBridge: bridge, caretLocation: -1, activeTokenIndices: [],
            precomputedTokens: parsed.tokens, classified: parsed.classified,
            precomputedBlocks: parsed.blocks, configuration: config
        )
        let table = parsed.tokens.first { $0.kind == .table }?.range ?? NSRange(location: 0, length: 0)
        #expect(styled.contains {
            NSIntersectionRange($0.range, table).length > 0 && $0.attributes[.latexImage] is NSImage
        })
        let wideAnchor = styled.first {
            NSIntersectionRange($0.range, table).length > 0 && $0.attributes[.scrollableBlockSourceID] is Int
        }
        let originalAnchorKern = wideAnchor?.attributes[.kern] as? CGFloat
        #expect(originalAnchorKern != nil)
        for kind in [MarkdownTokenKind.imageEmbed, .imageLink] {
            let range = parsed.tokens.first { $0.kind == kind }?.range ?? NSRange(location: 0, length: 0)
            let bounds = styled.first {
                NSIntersectionRange($0.range, range).length > 0 && $0.attributes[.latexBounds] is NSValue
            }?.attributes[.latexBounds] as? NSValue
            #expect(bounds?.rectValue.width == 200 - MarkdownTextLayoutFragment.markdownFenceRailWidth)
        }
        for kind in [MarkdownTokenKind.inlineLatex, .blockLatex] {
            let range = parsed.tokens.first { $0.kind == kind }?.range ?? NSRange(location: 0, length: 0)
            #expect(styled.contains {
                NSIntersectionRange($0.range, range).length > 0 && $0.attributes[.latexImage] is NSImage
            })
        }

        // A narrow editor makes the table scrollable. Its visible anchor must
        // use the remaining width, and a table-only resize pass must preserve
        // the fence attributes on the collapsed source paragraph.
        view.string = text
        view.layoutBridge = bridge
        view.setFrameSize(NSSize(width: 80, height: 500))
        view.textContainer?.size.width = 80
        let (font, paragraph) = TextStylingService.makeBaseFontAndStyle(
            fontName: "SF Pro", fontSize: 16, layoutBridge: bridge, configuration: config
        )
        let anchors = TextStylingService.restyle(
            textView: view, layoutBridge: bridge,
            paragraphCandidates: [table], baseFont: font, paragraphStyle: paragraph,
            caretLocation: -1, activeTokenIndices: [], wikiLinkIDProvider: { _ in nil },
            precomputedTokens: parsed.tokens, classified: parsed.classified,
            precomputedBlocks: parsed.blocks, sourceText: text, content: .tables,
            configuration: config
        )
        #expect(anchors.count == 1)
        if let anchor = anchors.first, let storage = view.textStorage {
            let location = anchor.location
            let resizedKern = storage.attribute(.kern, at: location, effectiveRange: nil) as? CGFloat
            if let originalAnchorKern, let resizedKern {
                #expect(abs(originalAnchorKern - resizedKern - 120) < 0.01)
            } else {
                Issue.record("Missing wide table anchor width")
            }
            #expect(storage.attribute(.markdownFenceDepth, at: location, effectiveRange: nil) as? Int == 2)
        }
        let imageRange = parsed.tokens.first { $0.kind == .imageLink }?.range ?? NSRange(location: 0, length: 0)
        _ = TextStylingService.restyle(
            textView: view, layoutBridge: bridge,
            paragraphCandidates: [imageRange], baseFont: font, paragraphStyle: paragraph,
            caretLocation: -1, activeTokenIndices: [], wikiLinkIDProvider: { _ in nil },
            precomputedTokens: parsed.tokens, classified: parsed.classified,
            precomputedBlocks: parsed.blocks, sourceText: text, content: .tables,
            configuration: config
        )
        var resizedImage: NSValue?
        view.textStorage?.enumerateAttribute(.latexBounds, in: imageRange) { value, _, stop in
            if let bounds = value as? NSValue {
                resizedImage = bounds
                stop.pointee = true
            }
        }
        #expect(resizedImage?.rectValue.width == 80 - MarkdownTextLayoutFragment.markdownFenceRailWidth)
        let mathRange = parsed.tokens.first { $0.kind == .blockLatex }?.range ?? NSRange(location: 0, length: 0)
        _ = TextStylingService.restyle(
            textView: view, layoutBridge: bridge,
            paragraphCandidates: [mathRange], baseFont: font, paragraphStyle: paragraph,
            caretLocation: -1, activeTokenIndices: [], wikiLinkIDProvider: { _ in nil },
            precomputedTokens: parsed.tokens, classified: parsed.classified,
            precomputedBlocks: parsed.blocks, sourceText: text, configuration: config
        )
        let mathStyle = view.textStorage?.attribute(
            .paragraphStyle, at: mathRange.location, effectiveRange: nil
        ) as? NSParagraphStyle
        #expect(mathStyle?.firstLineHeadIndent == MarkdownTextLayoutFragment.markdownFenceRailWidth)
    }

    @Test("Nested Markdown token expansion has no fixed depth limit")
    func deeperFences() {
        let levels = Array((3...12).reversed())
        let openings = levels.map { String(repeating: "`", count: $0) + "markdown\n# Level \($0)\n" }
        let closings = levels.reversed().map { String(repeating: "`", count: $0) + "\n" }
        let text = (openings + closings).joined()
        let parsed = coordinator(text, enabled: true).parsedDocument(for: text)
        #expect(parsed.tokens.filter { $0.kind == .codeBlock }.count == levels.count)
        #expect(parsed.tokens.filter { $0.kind == .heading }.count == levels.count)
    }

    @Test("Each nested Markdown body carries its own visual depth")
    func depthStyling() {
        _ = NSApplication.shared
        let text = "`````markdown\n# Outer\n````markdown\n## Middle\n```markdown\n### Inner\n```\n````\n`````\n"
        var config = MarkdownEditorConfiguration.default
        config.renderMarkdownCodeFences = true
        let ns = text as NSString
        let positions = ["# Outer", "## Middle", "### Inner"].map { ns.range(of: $0).location }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: name) else {
                Issue.record("Missing \(name) appearance")
                continue
            }
            appearance.performAsCurrentDrawingAppearance {
                let styled = MarkdownASTStyler.styleAttributes(
                    text: text, fontName: "SF Pro", fontSize: 16, configuration: config
                )
                let storage = NSMutableAttributedString(string: text)
                for item in styled { storage.addAttributes(item.attributes, range: item.range) }
                let depths = positions.map {
                    storage.attribute(.markdownFenceDepth, at: $0, effectiveRange: nil) as? Int
                }
                #expect(depths == [1, 2, 3])
                let fills = positions.compactMap {
                    (storage.attribute(.markdownFenceBackground, at: $0, effectiveRange: nil) as? NSColor)?
                        .usingColorSpace(.deviceRGB)
                }
                #expect(fills.count == 3 && fills[0] != fills[1] && fills[1] != fills[2])
                let rails = positions.map {
                    (storage.attribute(.markdownFenceRailColors, at: $0, effectiveRange: nil) as? [NSColor])?
                        .compactMap { $0.usingColorSpace(.deviceRGB) } ?? []
                }
                #expect(rails == [[], Array(fills.prefix(1)), Array(fills.prefix(2))])
                // The fragment paints the full-width fill. A glyph background
                // would cover a rail where text crosses the left edge.
                #expect(positions.allSatisfy {
                    storage.attribute(.backgroundColor, at: $0, effectiveRange: nil) == nil
                })
            }
        }
    }

    @Test("Nested content indents without losing its paragraph layout")
    func depthIndentation() {
        let text = """
        ``````markdown
        # Outer
        `````markdown
        ## Middle
        A middle paragraph\twith a tab and enough words to wrap
        - middle list item with enough words to wrap
        > middle quote
        ````markdown
        ### Inner
        - inner list item with enough words to wrap
        ```swift
        let value = 1
        ```
        ````
        `````
        ``````

        """
        var config = MarkdownEditorConfiguration.default
        config.renderMarkdownCodeFences = true
        let ns = text as NSString
        let styled = MarkdownASTStyler.styleAttributes(
            text: text, fontName: "SF Pro", fontSize: 16, configuration: config
        )
        let (_, baseStyle) = TextStylingService.makeBaseFontAndStyle(
            fontName: "SF Pro", fontSize: 16, configuration: config
        )
        let base: [NSAttributedString.Key: Any] = [.paragraphStyle: baseStyle]
        let unindented = NSMutableAttributedString(string: text, attributes: base)
        for item in styled { unindented.addAttributes(item.attributes, range: item.range) }
        let indented = NSMutableAttributedString(string: text)
        TextStylingService.applyStyledRanges(
            styled, paragraphs: [NSRange(location: 0, length: ns.length)],
            baseAttributes: base, to: indented
        )
        let initialLoad = NSMutableAttributedString(string: text)
        for (range, attributes) in MarkdownStyler.flattenedRuns(
            styled, base: base, documentLength: ns.length
        ) {
            initialLoad.setAttributes(attributes, range: range)
        }
        TextStylingService.indentMarkdownFenceParagraphs(
            in: initialLoad, ranges: [NSRange(location: 0, length: ns.length)]
        )
        let innerLocation = ns.range(of: "### Inner").location
        TextStylingService.applyStyledRanges(
            styled, paragraphs: [ns.paragraphRange(for: NSRange(location: innerLocation, length: 0))],
            baseAttributes: base, to: indented
        )

        for (label, depth) in [
            ("# Outer", 1), ("## Middle", 2), ("A middle", 2), ("- middle", 2),
            ("> middle", 2), ("### Inner", 3), ("- inner", 3),
            ("```swift", 4), ("let value", 4),
        ] {
            let location = ns.range(of: label).location
            #expect(location != NSNotFound)
            guard location != NSNotFound,
                  let original = unindented.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle,
                  let shifted = indented.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle else {
                Issue.record("Missing paragraph style for \(label)")
                continue
            }
            let offset = CGFloat(depth - 1) * MarkdownTextLayoutFragment.markdownFenceRailWidth
            #expect(shifted.firstLineHeadIndent == original.firstLineHeadIndent + offset)
            #expect(shifted.headIndent == original.headIndent + offset)
            #expect(shifted.tailIndent == original.tailIndent)
            #expect(shifted.lineBreakMode == original.lineBreakMode)
            if depth > 1 && original.tabStops.isEmpty && original.defaultTabInterval > 0 {
                #expect(shifted.tabStops.first?.location == offset + original.defaultTabInterval)
                #expect(shifted.tabStops.dropFirst().first?.location == offset + 2 * original.defaultTabInterval)
            } else {
                #expect(shifted.tabStops.map(\.location) == original.tabStops.map { $0.location + offset })
            }
            let loaded = initialLoad.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
            #expect(loaded?.firstLineHeadIndent == shifted.firstLineHeadIndent)
            #expect(loaded?.headIndent == shifted.headIndent)
        }
    }

    @Test("Nested list columns move with their enclosing fence")
    func nestedListColumns() throws {
        _ = NSApplication.shared
        let text = """
        ````markdown
        - root-a
        \t- root-b
        \t\t- root-c

        ```markdown
        - inner-a
        \t- inner-b
        \t\t- inner-c
        ```
        ````

        """
        var config = MarkdownEditorConfiguration.default
        config.renderMarkdownCodeFences = true
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        tv.configuration = config
        let tlm = try #require(tv.textLayoutManager)
        let bridge = LayoutBridge(tlm)
        let delegate = MarkdownLayoutManagerDelegate()
        tlm.delegate = delegate
        let (font, style) = TextStylingService.makeBaseFontAndStyle(
            fontName: "SF Pro", fontSize: 16, layoutBridge: bridge, configuration: config
        )
        tv.baseFont = font
        tv.textContainer?.size = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
        let ns = text as NSString
        let storage = NSMutableAttributedString(string: text, attributes: [.font: font, .paragraphStyle: style])
        let styled = MarkdownASTStyler.styleAttributes(
            text: text, fontName: "SF Pro", fontSize: 16, configuration: config
        )
        TextStylingService.applyStyledRanges(
            styled, paragraphs: [NSRange(location: 0, length: ns.length)],
            baseAttributes: [.font: font, .paragraphStyle: style], to: storage
        )
        tv.textStorage?.setAttributedString(storage)
        let container = try #require(tv.textContainer)
        tlm.ensureLayout(for: tlm.documentRange)
        for level in ["a", "b", "c"] {
            let root = ns.range(of: "root-\(level)")
            let inner = ns.range(of: "inner-\(level)")
            let rootX = bridge.boundingRect(forCharacterRange: root, in: container).minX
            let innerX = bridge.boundingRect(forCharacterRange: inner, in: container).minX
            #expect(abs((innerX - rootX) - MarkdownTextLayoutFragment.markdownFenceRailWidth) < 1,
                    "list level \(level): root x=\(rootX), inner x=\(innerX)")
        }
    }

    @Test("A nested ordinary code fence stays code")
    func nestedOrdinaryCode() {
        let text = "````markdown\n```swift\n# Literal\n```\n````\n"
        let parsed = coordinator(text, enabled: true).parsedDocument(for: text)
        let location = (text as NSString).range(of: "# Literal").location
        #expect(MarkdownDetection.isInsideCodeBlock(location: location, codeTokens: parsed.codeTokens))
        #expect(!parsed.tokens.contains { $0.kind == .heading && $0.range.location == location })
        let code = parsed.codeTokens.first { $0.kind == .codeBlock }
        #expect(code.flatMap { MarkdownTokenizer.extractLanguage(from: $0, in: text) } == "swift")

        var config = MarkdownEditorConfiguration.default
        config.renderMarkdownCodeFences = true
        let styled = MarkdownASTStyler.styleAttributes(
            text: text, fontName: "SF Pro", fontSize: 16, configuration: config
        )
        let storage = NSMutableAttributedString(string: text)
        for item in styled { storage.addAttributes(item.attributes, range: item.range) }
        #expect(storage.attribute(.markdownFenceDepth, at: location, effectiveRange: nil) as? Int == 2)
        let parent = (storage.attribute(.markdownFenceBackground, at: (text as NSString).range(of: "markdown").location,
                                      effectiveRange: nil) as? NSColor)
        let rails = storage.attribute(.markdownFenceRailColors, at: location, effectiveRange: nil) as? [NSColor]
        #expect(rails == [parent].compactMap { $0 })
    }

    @Test("Return completes a Markdown fence and leaves the caret inside its body")
    func openingCompletion() {
        _ = NSApplication.shared
        let text = "```markdown"
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        let delegate = coordinator(text, enabled: true)
        view.configuration.renderMarkdownCodeFences = true
        view.delegate = delegate
        delegate.textView = view
        view.string = text
        view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        view.insertText("\n", replacementRange: view.selectedRange())
        #expect(view.string == "```markdown\n\n```\n")
        #expect(view.selectedRange() == NSRange(location: 12, length: 0))
    }

    @Test("New fence before another block gets its own closing marker")
    func openingBeforeExistingBlock() {
        _ = NSApplication.shared
        let text = "```markdown\n\n```markdown\n# Existing\n```\n"
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        let delegate = coordinator(text, enabled: true)
        view.configuration.renderMarkdownCodeFences = true
        view.delegate = delegate
        delegate.textView = view
        view.string = text
        view.setSelectedRange(NSRange(location: 11, length: 0))
        view.insertText("\n", replacementRange: view.selectedRange())
        #expect(view.string == "```markdown\n\n```\n\n```markdown\n# Existing\n```\n")
        #expect(view.selectedRange() == NSRange(location: 12, length: 0))
    }

    @Test("An outer closing fence does not suppress inner fence completion")
    func openingInsideLongerFence() {
        _ = NSApplication.shared
        let text = "````markdown\n```markdown\n\n````\n"
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        let delegate = coordinator(text, enabled: true)
        view.configuration.renderMarkdownCodeFences = true
        view.delegate = delegate
        delegate.textView = view
        view.string = text
        view.setSelectedRange(NSRange(location: 24, length: 0))
        view.insertText("\n", replacementRange: view.selectedRange())
        #expect(view.string == "````markdown\n```markdown\n\n```\n\n````\n")
    }
}
