import Foundation
import Testing
@testable import MarkdownEngine

@Suite struct MarkdownSourceSnapshotTests {
    private func assertRanges(_ nodes: [MarkdownSourceSnapshot.Node], in source: String, within parent: NSRange) {
        let ns = source as NSString
        var cursor = parent.location
        for node in nodes {
            #expect(node.range.location == cursor)
            #expect(NSMaxRange(node.range) <= NSMaxRange(parent))
            for leaf in node.textRanges {
                #expect(NSIntersectionRange(leaf, node.range) == leaf)
                #expect(Range(leaf, in: source) != nil)
            }
            for span in node.inlineSpans {
                #expect(NSIntersectionRange(span.range, node.range) == span.range)
                #expect(NSIntersectionRange(span.sourceRange, node.range) == span.sourceRange)
                #expect(Range(span.range, in: source) != nil)
                #expect(Range(span.sourceRange, in: source) != nil)
            }
            if !node.children.isEmpty {
                let start = node.children[0].range.location
                let end = NSMaxRange(node.children.last!.range)
                #expect(start >= node.range.location && end <= NSMaxRange(node.range))
                assertRanges(node.children, in: source, within: NSRange(location: start, length: end - start))
            }
            #expect(ns.substring(with: node.range).utf16.count == node.range.length)
            cursor = NSMaxRange(node.range)
        }
        #expect(cursor == NSMaxRange(parent))
    }

    @Test func sourceProjectionPreservesPhysicalRanges() {
        let documents = [
            "> - Parent\r\n>   - 👩🏽‍💻 Café e\u{301}\r\n>\r\n>   continuation\r\n",
            "- Parent\n  paragraph one\n\n  paragraph two\n\n  - Child\n    child body\n\n- Tail\n",
            "> First\n>\n> > Inner\n> >\n> > Last\n",
            "- Parent\n\t- Tab child\n- Tail",
            "> Prefix-only final line\n>",
            "- Item\n  continuation\n\n> Quote outside\n",
            "````markdown\n> - Parent\n>   - Child\n````\n"
        ]
        var config = MarkdownEditorConfiguration.default
        config.renderMarkdownCodeFences = true
        for document in documents {
            let snapshot = MarkdownSourceSnapshot(document, configuration: config)
            assertRanges(snapshot.blocks, in: document, within: NSRange(location: 0, length: document.utf16.count))
        }
    }

    @Test func quoteTextLeavesExcludePhysicalPrefixes() {
        let source = "> **First** line\n> second line\n"
        let paragraph = MarkdownSourceSnapshot(source).blocks[0].children[0]
        let words = paragraph.textRanges.map { (source as NSString).substring(with: $0) }.joined()
        #expect(!words.contains(">"))
        #expect(words.contains("First"))
        #expect(words.contains("second line"))
    }

    @Test func attributesDescribeStructureWithoutExposingAST() {
        let snapshot = MarkdownSourceSnapshot("## Heading\n\n12) Task\n    - Child\n\n```swift\nlet x = 1\n```\n")
        #expect(snapshot.blocks[0].attributes.headingLevel == 2)
        let list = snapshot.blocks.first { $0.kind == .list }!
        #expect(list.children[0].attributes.listMarker == "12)")
        #expect(list.children[0].children[1].children[0].attributes.listMarker == "-")
        let fence = snapshot.blocks.first { $0.kind == .code }!
        #expect(fence.attributes.fenceInfo == "swift")
        #expect(fence.attributes.isClosedFence == true)
    }

    @Test func nestedQuoteFenceMetadataUsesLogicalSource() {
        let closed = MarkdownSourceSnapshot("> ```swift\n> let x = 1\n> ```\n")
        #expect(closed.blocks[0].children[0].attributes.isClosedFence == true)
        let open = MarkdownSourceSnapshot("> ```swift\n> let x = 1\n")
        #expect(open.blocks[0].children[0].attributes.isClosedFence == false)
    }

    @Test func inlineSpansRetainNestedTraitsAndSourceScopes() {
        let source = "> - Read **[important](destination)** and `value`.\r\n"
        let spans = MarkdownSourceSnapshot(source).blocks[0].children[0].children[0].children[0].inlineSpans
        let important = spans.first { (source as NSString).substring(with: $0.range) == "important" }!
        #expect(important.traits.contains("link:destination"))
        #expect(important.traits.contains { $0.hasPrefix("emphasis:") })
        #expect((source as NSString).substring(with: important.sourceRange) == "**[important](destination)**")
        #expect(spans.contains { $0.traits.contains { $0.hasPrefix("code:") } })
    }

    @Test func deeplyNestedContainersStopConservatively() {
        let source = String(repeating: "> ", count: 100) + "Text\n"
        let snapshot = MarkdownSourceSnapshot(source)
        assertRanges(snapshot.blocks, in: source, within: NSRange(location: 0, length: source.utf16.count))
        var node = snapshot.blocks[0], depth = 0
        while let child = node.children.first { depth += 1; node = child }
        #expect(depth <= 16)
    }
}
