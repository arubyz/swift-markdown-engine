//
//  NativeTextView+FenceBackground.swift
//  MarkdownEngine
//
//  Full-width fence fills and nesting rails live in NSTextView's documented
//  background pass, underneath TextKit's selection and fragment surfaces.
//

import AppKit

extension NativeTextView {
    struct FenceBackground {
        let rect: CGRect
        let color: NSColor
        let railColors: [NSColor]
    }

    func drawFenceBackgrounds(in dirtyRect: NSRect) {
        for background in fenceBackgrounds(in: dirtyRect) {
            background.color.setFill()
            NSBezierPath(rect: background.rect).fill()
            for (level, color) in background.railColors.enumerated() {
                color.setFill()
                NSBezierPath(rect: CGRect(
                    x: background.rect.minX + CGFloat(level) * MarkdownTextLayoutFragment.markdownFenceRailWidth,
                    y: background.rect.minY,
                    width: MarkdownTextLayoutFragment.markdownFenceRailWidth,
                    height: background.rect.height
                )).fill()
            }
        }
    }

    func fenceBackgrounds(in dirtyRect: NSRect) -> [FenceBackground] {
        guard let tlm = textLayoutManager,
              let storage = textStorage,
              let tcs = tlm.textContentManager as? NSTextContentStorage,
              let container = tlm.textContainer else { return [] }
        let width = container.size.width
        guard width.isFinite, width > 0 else { return [] }
        let origin = textContainerOrigin
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let start = tlm.textViewportLayoutController.viewportRange?.location ?? tlm.documentRange.location
        var result: [FenceBackground] = []
        tlm.enumerateTextLayoutFragments(from: start, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame
            let minY = origin.y + frame.minY
            if minY > dirtyRect.maxY { return false }
            if origin.y + frame.maxY < dirtyRect.minY { return true }
            if let hidden = writingToolsHiddenRemainder,
               fragment.rangeInElement.location.compare(hidden.endLocation) != .orderedAscending {
                return true
            }
            let location = tcs.offset(from: tcs.documentRange.location, to: fragment.rangeInElement.location)
            guard location != NSNotFound, location >= 0, location < storage.length,
                  let color = storage.attribute(.markdownFenceBackground, at: location, effectiveRange: nil) as? NSColor else {
                return true
            }
            var height = frame.height
            if fragment.textLineFragments.count > 1,
               let last = fragment.textLineFragments.last,
               last.characterRange.length == 0 {
                height -= last.typographicBounds.height
            }
            let top = floor(minY * scale) / scale
            let bottom = ceil((minY + height) * scale) / scale
            guard bottom > top else { return true }
            let rails = storage.attribute(.markdownFenceRailColors, at: location, effectiveRange: nil) as? [NSColor] ?? []
            result.append(FenceBackground(
                rect: CGRect(x: origin.x, y: top, width: width, height: bottom - top),
                color: color, railColors: rails
            ))
            return true
        }
        return result
    }
}
