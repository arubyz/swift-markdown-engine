//
//  MarkdownTokenizer.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// The token namespace. Tokens are produced by `parseTokensViaAST`
// (`BlockScopedTokenizer`): block structure + block-level tokens come from
// `BlockParser` + `BlockLevelTokenizer` (hand scanners, no regex), inline
// tokens from the AST (`InlineParser` → `InlineASTAdapter`). This file keeps
// only the code-block language helper.
import Foundation

// MARK: - Tokenizer
enum MarkdownTokenizer {

    private static let markdownFenceOpening = try! NSRegularExpression(
        pattern: #"^`{3,}[ \t]*markdown[ \t]*\r?\n$"#, options: [.caseInsensitive]
    )

    static func isMarkdownFence(openingLine: NSRange, in text: NSString) -> Bool {
        guard openingLine.length > 0, NSMaxRange(openingLine) <= text.length else { return false }
        let line = text.substring(with: openingLine)
        return markdownFenceOpening.firstMatch(
            in: line, range: NSRange(location: 0, length: (line as NSString).length)
        ) != nil
    }

    /// Body of a closed `markdown` fence, in the parent document's coordinates.
    /// The normal code-block token remains the source of truth for fence pairing.
    static func markdownFenceBody(_ token: MarkdownToken, in text: NSString) -> NSRange? {
        guard token.kind == .codeBlock,
              token.markerRanges.count == 2,
              isMarkdownFence(openingLine: token.markerRanges[0], in: text) else { return nil }
        return token.contentRange
    }

    // MARK: - Code Block Helpers

    static func extractLanguage(from token: MarkdownToken, in text: String) -> String? {
        guard token.kind == .codeBlock,
              let openingMarker = token.markerRanges.first,
              openingMarker.length > 4 else { return nil }

        let nsText = text as NSString
        let openingLine = nsText.substring(with: openingMarker)
        let markerLength = CodeFence.markerLength(in: openingLine)
        guard markerLength >= 3 else { return nil }
        let langRange = NSRange(
            location: openingMarker.location + markerLength,
            length: openingMarker.length - markerLength
        )

        guard langRange.location + langRange.length <= nsText.length else { return nil }

        let langString = nsText.substring(with: langRange).trimmingCharacters(in: .whitespacesAndNewlines)
        return langString.isEmpty ? nil : langString
    }
}
