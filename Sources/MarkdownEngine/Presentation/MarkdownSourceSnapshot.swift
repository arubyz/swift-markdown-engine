import Foundation

/// A source-preserving projection of the engine's parser. All ranges are UTF-16.
/// Consumers need not depend on the internal AST or its styling implementation.
public struct MarkdownSourceSnapshot: Sendable {
    public struct Node: Sendable {
        public enum Kind: String, Sendable {
            case paragraph, heading, quote, list, listItem, code, markdownFence
            case table, math, rule, blank, custom
        }
        public let kind: Kind
        public let range: NSRange
        public let children: [Node]
        /// Plain text leaves suitable for word comparison; syntax is excluded.
        public let textRanges: [NSRange]
    }

    public let source: String
    public let blocks: [Node]

    public init(_ source: String, configuration: MarkdownEditorConfiguration = .default) {
        self.source = source
        self.blocks = Self.parse(source, offset: 0, configuration: configuration, depth: 0)
    }

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
            var children: [Node] = []
            var texts: [NSRange] = []
            switch block {
            case .paragraph(_, let inlines): kind = .paragraph; texts = leaves(inlines)
            case .heading(_, _, _, let inlines): kind = .heading; texts = leaves(inlines)
            case .blockquote(_, let inlines): kind = .quote; texts = leaves(inlines)
            case .list(_, let items):
                kind = .list
                // Keep an item and its nested descendants atomic. The engine's
                // list AST is line-based; don't expose a nested line as an
                // independently removable parentless item.
                var i = 0
                while i < items.count {
                    let start = i
                    i += 1
                    while i < items.count, items[i].indent > items[start].indent { i += 1 }
                    let range = NSRange(location: items[start].range.location,
                                        length: NSMaxRange(items[i - 1].range) - items[start].range.location)
                    children.append(Node(kind: .listItem, range: shifted(range), children: [],
                                         textRanges: items[start..<i].flatMap { leaves($0.inlines) }))
                }
            case .codeBlock(let range):
                kind = .code
                let open = ns.lineRange(for: NSRange(location: range.location, length: 0))
                let close = ns.lineRange(for: NSRange(location: NSMaxRange(range) - 1, length: 0))
                let opening = ns.substring(with: open)
                if configuration.renderMarkdownCodeFences, depth < 64,
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
            case .ext: kind = .custom
            }
            return Node(kind: kind, range: shifted(block.range), children: children, textRanges: texts)
        }
        // The rendering parser emits continuation paragraphs separately from
        // list-marker lines. Attach indented continuations (and intervening
        // blank lines) to the preceding complete item for source consumers.
        var result: [Node] = []
        var index = 0
        while index < parsed.count {
            var node = parsed[index]
            index += 1
            if node.kind == .list, !node.children.isEmpty {
                var children = node.children
                var end = NSMaxRange(node.range)
                while index < parsed.count {
                    var next = index
                    while next < parsed.count, parsed[next].kind == .blank { next += 1 }
                    guard next < parsed.count else { break }
                    let candidate = parsed[next]
                    let local = NSRange(location: candidate.range.location - offset, length: candidate.range.length)
                    let value = ns.substring(with: local)
                    guard candidate.kind == .paragraph, value.hasPrefix("  ") || value.hasPrefix("\t") else { break }
                    let previous = children.removeLast()
                    end = NSMaxRange(candidate.range)
                    children.append(Node(kind: .listItem,
                        range: NSRange(location: previous.range.location, length: end - previous.range.location),
                        children: [], textRanges: previous.textRanges + candidate.textRanges))
                    index = next + 1
                }
                node = Node(kind: .list, range: NSRange(location: node.range.location, length: end - node.range.location),
                            children: children, textRanges: [])
            }
            result.append(node)
        }
        return result
    }
}
