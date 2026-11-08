import AppKit

/// A slice is styled in its ORIGINAL document, then projected into the display.
/// Adjacent slices are never reparsed as one synthetic Markdown document.
public struct MarkdownRenderSlice: Sendable {
    public enum Emphasis: Sendable { case none, insertion, deletion }
    public let source: String
    public let range: NSRange
    public let emphasis: Emphasis

    public init(source: String, range: NSRange, emphasis: Emphasis = .none) {
        self.source = source
        self.range = range
        self.emphasis = emphasis
    }
}

/// Engine-owned read-only TextKit surface for composed documents. The host owns
/// scrolling, margins and controls. Retain the renderer as long as its view lives.
@MainActor
public final class MarkdownFragmentRenderer {
    private let native = NativeTextView(frame: .zero)
    private let layoutDelegate = MarkdownLayoutManagerDelegate()
    private let bridge: LayoutBridge
    public var textView: NSTextView { native }
    public private(set) var contentHeight: CGFloat = 0

    public init() {
        bridge = LayoutBridge(native.textLayoutManager!)
        native.layoutBridge = bridge
        native.textLayoutManager?.delegate = layoutDelegate
        native.isEditable = false
        native.isSelectable = true
        native.isRichText = true
        native.allowsUndo = false
        native.drawsBackground = false
        native.isVerticallyResizable = false
        native.isHorizontallyResizable = false
        native.textContainerInset = NSSize(width: 8, height: 8)
        native.textContainer?.widthTracksTextView = true
        native.textContainer?.heightTracksTextView = false
        native.isContinuousSpellCheckingEnabled = false
        if #available(macOS 15.0, *) { native.writingToolsBehavior = .none }
    }

    /// Re-render on width/theme/service changes. Slice ranges must be valid
    /// UTF-16 boundaries in their source. Returns their display ranges.
    @discardableResult
    public func render(_ slices: [MarkdownRenderSlice], width: CGFloat,
                       fontSize: CGFloat = 16,
                       configuration: MarkdownEditorConfiguration = .default) -> [NSRange] {
        var surfaceConfiguration = configuration
        surfaceConfiguration.readingWidth = nil // the host has already allocated the column
        native.configuration = surfaceConfiguration
        native.baseFont = .systemFont(ofSize: fontSize)
        native.isApplyingManagedFrameSize = true
        native.frame.size.width = max(40, width)
        native.isApplyingManagedFrameSize = false
        native.textContainer?.containerSize = NSSize(width: max(24, width - 16), height: .greatestFiniteMagnitude)
        let (font, paragraph) = TextStylingService.makeBaseFontAndStyle(
            fontName: native.baseFont.fontName, fontSize: fontSize, layoutBridge: bridge, configuration: configuration)
        let base = TextStylingService.makeBaseTypingAttributes(font: font, paragraphStyle: paragraph, theme: configuration.theme)
        var styled: [Data: NSAttributedString] = [:]
        let output = NSMutableAttributedString(string: "")
        var displayRanges: [NSRange] = []
        for slice in slices {
            let sourceKey = Data(slice.source.utf8)
            let ns = slice.source as NSString
            precondition(slice.range.location >= 0 && slice.range.length >= 0 &&
                         slice.range.location <= ns.length && slice.range.length <= ns.length - slice.range.location)
            if styled[sourceKey] == nil {
                let result = NSMutableAttributedString(string: slice.source, attributes: base)
                let attrs = MarkdownStyler.styleAttributes(
                    text: slice.source, fontName: font.fontName, fontSize: fontSize,
                    layoutBridge: bridge, caretLocation: -1, activeTokenIndices: [], configuration: configuration)
                TextStylingService.applyStyledRanges(attrs,
                    paragraphs: [NSRange(location: 0, length: ns.length)],
                    baseAttributes: base, to: result, fenceStyle: configuration.codeBlock)
                styled[sourceKey] = result
            }
            let fragment = NSMutableAttributedString(attributedString: styled[sourceKey]!.attributedSubstring(from: slice.range))
            let local = NSRange(location: 0, length: fragment.length)
            let display = NSRange(location: output.length, length: fragment.length)
            // The table overlay is the sole styled attribute containing an
            // absolute source range. Rebase it just like the visible text.
            fragment.enumerateAttribute(.scrollableBlockFullRange, in: local) { value, range, _ in
                guard let original = (value as? NSValue)?.rangeValue else { return }
                let clipped = NSIntersectionRange(original, slice.range)
                fragment.addAttribute(.scrollableBlockFullRange,
                    value: NSValue(range: NSRange(location: display.location + clipped.location - slice.range.location,
                                                  length: clipped.length)), range: range)
            }
            // Hidden source markers must remain invisible even in a changed
            // block; painting their background would reveal empty colored bars.
            fragment.enumerateAttributes(in: local) { attributes, range, _ in
                let color = attributes[.foregroundColor] as? NSColor
                guard color?.alphaComponent != 0 else { return }
                switch slice.emphasis {
                case .none: break
                case .insertion:
                    fragment.addAttribute(.backgroundColor, value: NSColor.systemGreen.withAlphaComponent(0.18), range: range)
                    fragment.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                case .deletion:
                    fragment.addAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.16), range: range)
                    fragment.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                }
            }
            if slice.emphasis == .insertion, output.length > 0,
               output.attribute(.strikethroughStyle, at: output.length - 1, effectiveRange: nil) != nil {
                output.addAttribute(.kern, value: 3, range: NSRange(location: output.length - 1, length: 1))
            }
            output.append(fragment)
            displayRanges.append(display)
        }
        let selection = native.selectedRange()
        native.textStorage?.setAttributedString(output)
        native.setSelectedRange(NSIntersectionRange(selection, NSRange(location: 0, length: output.length)))
        native.textLayoutManager?.ensureLayout(for: native.textLayoutManager!.documentRange)
        contentHeight = ceil(native.textLayoutManager?.usageBoundsForTextContainer.maxY ?? 0) + 24
        native.isApplyingManagedFrameSize = true
        native.frame.size.height = max(40, contentHeight)
        native.isApplyingManagedFrameSize = false
        native.updateWideTableOverlays()
        native.needsDisplay = true
        return displayRanges
    }

    /// Geometry in the text view's coordinates, after layout (for gutters).
    public func rect(for range: NSRange) -> CGRect {
        guard let container = native.textContainer, range.length > 0 else { return .zero }
        return bridge.boundingRect(forCharacterRange: range, in: container)
            .offsetBy(dx: native.textContainerOrigin.x, dy: native.textContainerOrigin.y)
    }
}
