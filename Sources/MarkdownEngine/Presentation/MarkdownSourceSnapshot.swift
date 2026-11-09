import Foundation

/// A source-preserving projection of the engine's parser. All ranges are UTF-16.
/// Consumers need not depend on the internal AST or its styling implementation.
public struct MarkdownSourceSnapshot: Sendable {
    public struct Node: Sendable {
        public enum Kind: String, Sendable {
            case paragraph, heading, quote, list, listItem, code, markdownFence
            case table, math, rule, blank, custom
        }
        /// Structural hints for source consumers; no renderer implementation types.
        public struct Attributes: Equatable, Sendable {
            public var headingLevel: Int?
            public var listMarker: String?
            public var indentation: String?
            /// Exact physical prefix before a list marker, including enclosing
            /// quote prefixes removed by the logical container projection.
            public var sourcePrefix: String?
            public var fenceInfo: String?
            public var isClosedFence: Bool?
            public var extensionID: String?
        }
        public let attributes: Attributes
        public let kind: Kind
        public let range: NSRange
        public let children: [Node]
        /// Plain text leaves suitable for word comparison; syntax is excluded.
        public let textRanges: [NSRange]
        public let inlineSpans: [MarkdownInlineSpan]

        init(kind: Kind, range: NSRange, children: [Node] = [], textRanges: [NSRange] = [],
             attributes: Attributes = Attributes(), inlineSpans: [MarkdownInlineSpan] = []) {
            self.kind = kind; self.range = range; self.children = children
            self.textRanges = textRanges; self.attributes = attributes; self.inlineSpans = inlineSpans
        }
    }

    public let source: String
    public let blocks: [Node]

    public init(_ source: String, configuration: MarkdownEditorConfiguration = .default) {
        self.source = source
        self.blocks = Self.parse(source, offset: 0, configuration: configuration, depth: 0)
    }

    // Snapshot construction also runs on small Swift concurrency worker stacks.
    // Deeper containers remain opaque, preserving their complete source span.
    private static let maximumDepth = 16

    private static func parse(_ source: String, offset: Int,
                              configuration: MarkdownEditorConfiguration, depth: Int) -> [Node] {
        let ns = source as NSString
        func shifted(_ range: NSRange) -> NSRange {
            NSRange(location: offset + range.location, length: range.length)
        }
        func leaves(_ nodes: [InlineNode]) -> [NSRange] {
            nodes.flatMap { node -> [NSRange] in
                switch node {
                case .text(let range): return [shifted(range)]
                case .emphasis(_, _, _, let children), .link(_, _, _, _, let children):
                    return leaves(children)
                case .ext(let ext): return leaves(ext.children)
                default: return []
                }
            }
        }
        let parsed: [Node] = DocumentAST.parse(source, registry: configuration.extensionRegistry).map { block in
            var kind: Node.Kind
            var attributes = Node.Attributes()
            var children: [Node] = []
            var texts: [NSRange] = []
            var inline: [MarkdownInlineSpan] = []
            switch block {
            case .paragraph(let range, let inlines):
                kind = .paragraph; texts = leaves(inlines); inline = MarkdownInlineSpan.project(inlines, in: ns, offset: offset)
                // The rendering parser leaves unclosed backtick fences in a
                // paragraph. Surface that fact to conservative source consumers.
                var cursor = range.location
                while cursor < NSMaxRange(range) {
                    let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
                    if CodeFence.markerLength(in: ns.substring(with: line)) >= 3 {
                        attributes.isClosedFence = false
                    }
                    cursor = NSMaxRange(line)
                }
            case .heading(let level, _, _, let inlines):
                kind = .heading; texts = leaves(inlines); inline = MarkdownInlineSpan.project(inlines, in: ns, offset: offset); attributes.headingLevel = level
            case .blockquote(let range, let inlines):
                kind = .quote; texts = leaves(inlines); inline = MarkdownInlineSpan.project(inlines, in: ns, offset: offset)
                if depth < maximumDepth {
                    children = projectedChildren(ns, range: range, offset: offset,
                        configuration: configuration, depth: depth, prefix: .quote)
                }
            case .list(_, let items):
                kind = .list
                // Build one source-owning item per sibling. Descendants are
                // parsed from a de-indented projection, then mapped back to
                // physical source lines (including their original prefixes).
                var i = 0
                while i < items.count {
                    let start = i
                    i += 1
                    while i < items.count, items[i].indent > items[start].indent { i += 1 }
                    let item = items[start]
                    let range = NSRange(location: item.range.location,
                                        length: NSMaxRange(items[i - 1].range) - item.range.location)
                    var hints = Node.Attributes()
                    hints.listMarker = ns.substring(with: item.marker)
                    hints.indentation = ns.substring(with: NSRange(location: item.range.location,
                        length: item.marker.location - item.range.location))
                    hints.sourcePrefix = hints.indentation
                    let header = Node(kind: .paragraph, range: shifted(item.range), textRanges: leaves(item.inlines),
                                      inlineSpans: MarkdownInlineSpan.project(item.inlines, in: ns, offset: offset))
                    var body: [Node] = [header]
                    if i > start + 1, depth < maximumDepth {
                        let contentIndent = NSMaxRange(item.marker) + 1 - item.range.location
                        let tail = NSRange(location: NSMaxRange(item.range), length: NSMaxRange(range) - NSMaxRange(item.range))
                        body += projectedChildren(ns, range: tail, offset: offset,
                            configuration: configuration, depth: depth, prefix: .indent(contentIndent))
                    }
                    children.append(Node(kind: .listItem, range: shifted(range), children: body,
                        textRanges: items[start..<i].flatMap { leaves($0.inlines) }, attributes: hints,
                        inlineSpans: body.flatMap(\.inlineSpans)))
                }
            case .codeBlock(let range):
                kind = .code
                let open = ns.lineRange(for: NSRange(location: range.location, length: 0))
                let close = ns.lineRange(for: NSRange(location: NSMaxRange(range) - 1, length: 0))
                let opening = ns.substring(with: open)
                attributes.fenceInfo = String(opening.trimmingCharacters(in: .whitespacesAndNewlines)
                    .drop(while: { $0 == "`" })).trimmingCharacters(in: .whitespaces)
                attributes.isClosedFence = close.location >= NSMaxRange(open) &&
                    CodeFence.isClosing(ns.substring(with: close), openingLength: CodeFence.markerLength(in: opening))
                if configuration.renderMarkdownCodeFences, depth < maximumDepth,
                   CodeFence.isMarkdownOpening(opening), close.location >= NSMaxRange(open),
                   CodeFence.isClosing(ns.substring(with: close), openingLength: CodeFence.markerLength(in: opening)) {
                    kind = .markdownFence
                    let body = NSRange(location: NSMaxRange(open), length: close.location - NSMaxRange(open))
                    children = parse(ns.substring(with: body), offset: offset + body.location,
                                     configuration: configuration, depth: depth + 1)
                }
            case .table: kind = .table
            case .blockLatex: kind = .math
            case .thematicBreak: kind = .rule
            case .blank: kind = .blank
            case .ext(let node): kind = .custom; attributes.extensionID = node.extensionID
            }
            return Node(kind: kind, range: shifted(block.range), children: children, textRanges: texts, attributes: attributes, inlineSpans: inline)
        }
        // The rendering AST splits a list at continuation paragraphs and blank
        // lines. Rejoin these source spans before projecting the complete item
        // bodies. This does not change the editor's parser or renderer.
        var result: [Node] = []
        var index = 0
        while index < parsed.count {
            var node = parsed[index]
            index += 1
            if node.kind == .list, !node.children.isEmpty {
                var items = node.children
                var end = NSMaxRange(node.range)
                while index < parsed.count {
                    var next = index
                    while next < parsed.count, parsed[next].kind == .blank { next += 1 }
                    guard next < parsed.count else { break }
                    let candidate = parsed[next]
                    let value = ns.substring(with: NSRange(location: candidate.range.location - offset,
                                                          length: candidate.range.length))
                    let last = items.last!
                    let indent = (last.attributes.indentation?.utf16.count ?? 0)
                    let required = indent + (last.attributes.listMarker?.utf16.count ?? 1) + 1
                    let leading = value.prefix(while: { $0 == " " || $0 == "\t" }).utf16.count
                    if candidate.kind == .list, let first = candidate.children.first,
                       (first.attributes.indentation?.utf16.count ?? 0) <= indent {
                        // Blank lines belong to the preceding item; this makes
                        // a loose-list separator travel with its owner.
                        if candidate.range.location > end {
                            items[items.count - 1] = extendingRange(last, to: candidate.range.location)
                        }
                        items += candidate.children
                    } else if leading >= required {
                        items[items.count - 1] = extendingRange(last, to: NSMaxRange(candidate.range))
                    } else { break }
                    end = NSMaxRange(candidate.range)
                    index = next + 1
                }
                items = items.map { item in
                    guard let last = item.children.last, NSMaxRange(last.range) < NSMaxRange(item.range) else { return item }
                    return extended(item, to: NSMaxRange(item.range), source: ns, offset: offset,
                                    configuration: configuration, depth: depth)
                }
                node = Node(kind: .list, range: NSRange(location: node.range.location, length: end - node.range.location),
                            children: items)
            }
            result.append(node)
        }
        return result
    }

    private static func extendingRange(_ item: Node, to end: Int) -> Node {
        Node(kind: item.kind, range: NSRange(location: item.range.location, length: end - item.range.location),
             children: item.children, textRanges: item.textRanges, attributes: item.attributes, inlineSpans: item.inlineSpans)
    }

    private static func extended(_ item: Node, to end: Int, source: NSString, offset: Int,
                                 configuration: MarkdownEditorConfiguration, depth: Int) -> Node {
        let header = item.children.first!
        let indent = (item.attributes.indentation?.utf16.count ?? 0) +
                     (item.attributes.listMarker?.utf16.count ?? 1) + 1
        let tail = NSRange(location: NSMaxRange(header.range) - offset,
                           length: end - NSMaxRange(header.range))
        let body = depth < maximumDepth ? projectedChildren(source, range: tail, offset: offset,
            configuration: configuration, depth: depth, prefix: .indent(indent)) : []
        return Node(kind: .listItem, range: NSRange(location: item.range.location, length: end - item.range.location),
                    children: [header] + body, textRanges: header.textRanges + body.flatMap(\.textRanges),
                    attributes: item.attributes, inlineSpans: header.inlineSpans + body.flatMap(\.inlineSpans))
    }

    private enum Prefix { case quote, indent(Int) }

    /// Parse a logical container body without losing a single source character.
    /// Block spans include removed prefixes; text leaves are split at physical
    /// line boundaries so a word diff never treats `>` or indentation as prose.
    private static func projectedChildren(_ ns: NSString, range: NSRange, offset: Int,
                                          configuration: MarkdownEditorConfiguration, depth: Int,
                                          prefix: Prefix) -> [Node] {
        struct Line { let logical: NSRange; let physical: NSRange; let content: Int }
        var lines: [Line] = [], text = "", length = 0, cursor = range.location
        while cursor < NSMaxRange(range) {
            let line = NSIntersectionRange(ns.lineRange(for: NSRange(location: cursor, length: 0)), range)
            var start = line.location
            switch prefix {
            case .quote:
                while start < NSMaxRange(line), ns.character(at: start) == 32 || ns.character(at: start) == 9 { start += 1 }
                guard start < NSMaxRange(line), ns.character(at: start) == 62 else { return [] }
                start += 1
                if start < NSMaxRange(line), ns.character(at: start) == 32 || ns.character(at: start) == 9 { start += 1 }
            case .indent(let count):
                var removed = 0
                while start < NSMaxRange(line), removed < count,
                      ns.character(at: start) == 32 || ns.character(at: start) == 9 { start += 1; removed += 1 }
            }
            let content = ns.substring(with: NSRange(location: start, length: NSMaxRange(line) - start))
            // A final prefix-only line has no logical characters; keep it
            // opaque rather than dropping its source range.
            guard !content.isEmpty else { return [] }
            lines.append(Line(logical: NSRange(location: length, length: content.utf16.count), physical: line, content: start))
            text += content; length += content.utf16.count; cursor = NSMaxRange(line)
        }
        guard !text.isEmpty else { return [] }
        func intersecting(_ range: NSRange) -> ArraySlice<Line> {
            var low = 0, high = lines.count
            while low < high {
                let mid = (low + high) / 2
                if NSMaxRange(lines[mid].logical) <= range.location { low = mid + 1 } else { high = mid }
            }
            let start = low
            high = lines.count
            while low < high {
                let mid = (low + high) / 2
                if lines[mid].logical.location < NSMaxRange(range) { low = mid + 1 } else { high = mid }
            }
            return lines[start..<low]
        }
        func map(_ node: Node) -> Node {
            let covered = intersecting(node.range)
            let first = covered.first!, last = covered.last!
            let mappedText = node.textRanges.flatMap { leaf in
                intersecting(leaf).compactMap { line -> NSRange? in
                    let intersection = NSIntersectionRange(line.logical, leaf)
                    guard intersection.length > 0 else { return nil }
                    return NSRange(location: offset + line.content + intersection.location - line.logical.location,
                                   length: intersection.length)
                }
            }
            func mappedRange(_ range: NSRange) -> NSRange {
                let covered = intersecting(range)
                let first = covered.first!, last = covered.last!
                let start = offset + first.content + range.location - first.logical.location
                let end = offset + last.content + NSMaxRange(range) - last.logical.location
                return NSRange(location: start, length: end - start)
            }
            let spans = node.inlineSpans.flatMap { span -> [MarkdownInlineSpan] in
                let pieces = span.isOpaque ? [span.range] : intersecting(span.range).map { NSIntersectionRange($0.logical, span.range) }
                return pieces.map { piece in
                    MarkdownInlineSpan(range: mappedRange(piece), sourceRange: mappedRange(span.sourceRange),
                                       traits: span.traits, isOpaque: span.isOpaque)
                }
            }
            var attributes = node.attributes
            if let prefix = attributes.sourcePrefix {
                attributes.sourcePrefix = ns.substring(with: NSRange(location: first.physical.location,
                    length: first.content - first.physical.location)) + prefix
            }
            return Node(kind: node.kind,
                range: NSRange(location: offset + first.physical.location,
                               length: NSMaxRange(last.physical) - first.physical.location),
                children: node.children.map(map), textRanges: mappedText, attributes: attributes, inlineSpans: spans)
        }
        return parse(text, offset: 0, configuration: configuration, depth: depth + 1).map(map)
    }
}
