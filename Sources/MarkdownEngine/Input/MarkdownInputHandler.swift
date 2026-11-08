//
//  MarkdownInputHandler.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Handles Markdown typing shortcuts, like continuing lists and keeping block
// LaTeX on its own line while you type.
import AppKit

enum MarkdownInputHandler {

    /// Complete a newly typed Markdown fence without replacing the text view.
    /// The extra blank line leaves the caret in an editable body paragraph.
    static func completeMarkdownFence(
        textView: NSTextView, affectedCharRange: NSRange, replacementString: String?,
        codeTokens: [MarkdownToken]
    ) -> Bool {
        guard replacementString == "\n", affectedCharRange.length == 0,
              (textView as? NativeTextView)?.configuration.renderMarkdownCodeFences == true else { return false }
        guard !MarkdownDetection.isInsideCodeBlock(location: affectedCharRange.location, codeTokens: codeTokens) else { return false }
        let source = textView.string as NSString
        let line = source.lineRange(for: NSRange(location: affectedCharRange.location, length: 0))
        let lineEnd = NSMaxRange(line)
        let endsWithNewline = lineEnd > line.location && source.character(at: lineEnd - 1) == 10
        guard affectedCharRange.location == lineEnd ||
                (endsWithNewline && affectedCharRange.location == lineEnd - 1) else { return false }
        let opening = source.substring(with: NSRange(
            location: line.location, length: affectedCharRange.location - line.location
        ))
        guard CodeFence.isMarkdownOpening(opening) else { return false }
        let marker = String(repeating: "`", count: CodeFence.markerLength(in: opening))
        let suffix = source.substring(from: affectedCharRange.location)
        let close = try! NSRegularExpression(pattern: #"^(?:[ \t]*\r?\n)*(`{3,})[ \t]*(?:\r?\n|$)"#)
        if let nextClose = close.firstMatch(
            in: suffix, range: NSRange(location: 0, length: (suffix as NSString).length)
        ), nextClose.range(at: 1).length == marker.utf16.count {
            return false
        }
        insertTextProgrammatically(
            textView, text: "\n\n" + marker + (suffix.hasPrefix("\n") ? "" : "\n"), at: affectedCharRange,
            cursorAfter: affectedCharRange.location + 1
        )
        return true
    }

    /// `codeTokens` (codeBlock + inlineCode, from the keystroke's existing
    /// parse) answers "is the caret in code?" without the O(doc) document
    /// scan the handler otherwise runs on every space/Enter/Tab.
    static func handleListInsertion(textView: NSTextView, affectedCharRange: NSRange, replacementString: String?, codeTokens: [MarkdownToken]? = nil) -> Bool {
        let isInsideCodeBlock = codeTokens.map {
            MarkdownDetection.isInsideCodeBlock(location: affectedCharRange.location, codeTokens: $0)
        }
        return MarkdownLists.handleInsertion(textView: textView, affectedCharRange: affectedCharRange,
                                             replacementString: replacementString, isInsideCodeBlock: isInsideCodeBlock)
    }

    // MARK: - Block LaTeX Auto-Wrap

    private static func insertTextProgrammatically(_ textView: NSTextView, text: String, at range: NSRange, cursorAfter: Int) {
        if let coord = textView.delegate as? NativeTextViewWrapper.Coordinator {
            coord.isProgrammaticEdit = true
            // Replaces a suppressed keystroke that never applied — reset its
            // pending count so this edit registers as the cycle's single
            // tracked edit and textDidChange keeps the trusted fast paths.
            coord.pendingEditCount = 0
        }
        textView.insertText(text, replacementRange: range)
        if let coord = textView.delegate as? NativeTextViewWrapper.Coordinator {
            coord.isProgrammaticEdit = false
        }
        textView.setSelectedRange(NSRange(location: cursorAfter, length: 0))
    }

    /// Keeps block LaTeX ($$...$$) on its own line by inserting newlines; returns true if handled.
    static func handleBlockLatexAutoWrap(
        textView: NSTextView,
        affectedCharRange: NSRange,
        replacementString: String?,
        blockLatexTokens: [MarkdownToken]? = nil
    ) -> Bool {
        let resolvedTokens: [MarkdownToken]
        if let blockLatexTokens {
            resolvedTokens = blockLatexTokens
        } else {
            resolvedTokens = MarkdownTokenizer.parseTokensViaAST(
                in: textView.string,
                registry: (textView as? NativeTextView)?.configuration.extensionRegistry ?? .empty
            ).filter { $0.kind == .blockLatex }
        }
        return handleBlockAutoWrap(textView: textView, affectedCharRange: affectedCharRange,
                                   replacementString: replacementString, tokens: resolvedTokens)
    }

    /// Return inside a table row inserts `<br>` instead of splitting the row.
    ///
    /// A GFM row is ONE source line, so a bare newline tears the table in half.
    /// `<br>` is the format's only in-cell line break, and the renderer draws
    /// it as one. Covers ⇧↵ too: AppKit sends the same `insertNewline:` for
    /// both, so both arrive here as a `"\n"` replacement.
    ///
    /// Deliberately NOT handled at the token's outer edges — Return at the very
    /// start or end of the table stays a normal newline, which is the only way
    /// out of a table that reaches the end of the document.
    static func handleTableCellNewline(
        textView: NSTextView,
        affectedCharRange: NSRange,
        replacementString: String?,
        tableTokens: [MarkdownToken]
    ) -> Bool {
        guard replacementString == "\n" else { return false }
        let start = affectedCharRange.location
        let end = NSMaxRange(affectedCharRange)
        guard tableTokens.contains(where: { start > $0.range.location && end < NSMaxRange($0.range) })
        else { return false }

        let insertion = "<br>"
        insertTextProgrammatically(
            textView,
            text: insertion,
            at: affectedCharRange,
            cursorAfter: start + (insertion as NSString).length
        )
        return true
    }

    /// Ensures image embeds (![[...]]) stay on their own line by automatically inserting newlines.
    static func handleImageEmbedAutoWrap(
        textView: NSTextView,
        affectedCharRange: NSRange,
        replacementString: String?,
        imageEmbedTokens: [MarkdownToken]? = nil
    ) -> Bool {
        let resolvedTokens: [MarkdownToken]
        if let imageEmbedTokens {
            resolvedTokens = imageEmbedTokens
        } else {
            resolvedTokens = MarkdownTokenizer.parseTokensViaAST(
                in: textView.string,
                registry: (textView as? NativeTextView)?.configuration.extensionRegistry ?? .empty
            ).filter { $0.kind == .imageEmbed }
        }
        return handleBlockAutoWrap(textView: textView, affectedCharRange: affectedCharRange,
                                   replacementString: replacementString, tokens: resolvedTokens)
    }

    /// Shared auto-wrap logic: ensures a block-level token stays on its own line.
    private static func handleBlockAutoWrap(
        textView: NSTextView,
        affectedCharRange: NSRange,
        replacementString: String?,
        tokens: [MarkdownToken]
    ) -> Bool {
        guard let replacement = replacementString,
              !replacement.isEmpty,
              replacement != "\n" else { return false }

        let text = textView.string as NSString
        let newlineChar = UInt16(("\n" as Character).asciiValue!)

        for token in tokens {
            let tokenEnd = NSMaxRange(token.range)

            // Typing right after closing marker
            if affectedCharRange.location == tokenEnd {
                if tokenEnd < text.length && text.character(at: tokenEnd) == newlineChar {
                    insertTextProgrammatically(textView, text: replacement,
                                               at: NSRange(location: tokenEnd + 1, length: 0),
                                               cursorAfter: tokenEnd + 1 + replacement.utf16.count)
                } else {
                    insertTextProgrammatically(textView, text: "\n" + replacement,
                                               at: affectedCharRange,
                                               cursorAfter: affectedCharRange.location + 1 + replacement.utf16.count)
                }
                return true
            }

            // Typing right before opening marker
            if affectedCharRange.location == token.range.location {
                if token.range.location > 0 && text.character(at: token.range.location - 1) == newlineChar {
                    insertTextProgrammatically(textView, text: replacement,
                                               at: NSRange(location: token.range.location - 1, length: 0),
                                               cursorAfter: token.range.location - 1 + replacement.utf16.count)
                } else {
                    insertTextProgrammatically(textView, text: replacement + "\n",
                                               at: affectedCharRange,
                                               cursorAfter: affectedCharRange.location + replacement.utf16.count)
                }
                return true
            }
        }

        return false
    }
}
