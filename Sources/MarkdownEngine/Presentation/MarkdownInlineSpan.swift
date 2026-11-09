import Foundation

/// A visible inline span and the source syntax that gives it meaning. Traits
/// are stable source signatures, not AppKit attributes, so comparison can run
/// off the main actor. Opaque spans (images, math, wiki links) stay indivisible.
public struct MarkdownInlineSpan: Sendable {
    public let range: NSRange
    public let sourceRange: NSRange
    public let traits: [String]
    public let isOpaque: Bool

    static func project(_ nodes: [InlineNode], in source: NSString, offset: Int) -> [Self] {
        func shifted(_ range: NSRange) -> NSRange { NSRange(location: range.location + offset, length: range.length) }
        func visit(_ nodes: [InlineNode], traits: [String], scope: NSRange?) -> [Self] {
            nodes.flatMap { node -> [Self] in
                func leaf(_ range: NSRange, syntax: NSRange? = nil, extra: [String] = [], opaque: Bool = false) -> [Self] {
                    guard range.length > 0 else { return [] }
                    return [Self(range: shifted(range), sourceRange: shifted(scope ?? syntax ?? range),
                                 traits: traits + extra, isOpaque: opaque)]
                }
                switch node {
                case .text(let range): return leaf(range)
                case .emphasis(_, let range, let markers, let children):
                    let signature = markers.map { source.substring(with: $0) }.joined(separator: "|")
                    return visit(children, traits: traits + ["emphasis:" + signature], scope: scope ?? range)
                case .link(let range, _, let url, _, let children):
                    return visit(children, traits: traits + ["link:" + source.substring(with: url)], scope: scope ?? range)
                case .code(let range, let content):
                    let open = source.substring(with: NSRange(location: range.location, length: content.location - range.location))
                    let close = source.substring(with: NSRange(location: NSMaxRange(content), length: NSMaxRange(range) - NSMaxRange(content)))
                    return leaf(content.length > 0 ? content : range, syntax: range, extra: ["code:" + open + "|" + close])
                case .escape(let range, let character, _):
                    return leaf(character, syntax: range, extra: ["escape"])
                case .ext(let ext):
                    if ext.children.isEmpty { return leaf(ext.range, opaque: true) }
                    let signature = ext.markers.map { source.substring(with: $0) }.joined(separator: "|")
                    return visit(ext.children, traits: traits + ["extension:" + ext.extensionID + ":" + signature], scope: scope ?? ext.range)
                case .image(let range, _, _, _), .wikiLink(let range, _, _, _),
                     .imageEmbed(let range, _, _), .inlineLatex(let range, _, _):
                    return leaf(range, opaque: true)
                }
            }
        }
        return visit(nodes, traits: [], scope: nil)
    }
}
