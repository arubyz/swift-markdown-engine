import Foundation

/// Backtick fence rules shared by block classification and token ranges.
enum CodeFence {
    static func isMarkdownOpening(_ line: String) -> Bool {
        let count = markerLength(in: line)
        guard count >= 3 else { return false }
        return (line as NSString).substring(from: count)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "markdown"
    }

    static func markerLength(in line: String) -> Int {
        let text = line as NSString
        var count = 0
        while count < text.length, text.character(at: count) == 0x60 { count += 1 }
        return count >= 3 ? count : 0
    }

    static func isClosing(_ line: String, openingLength: Int) -> Bool {
        let count = markerLength(in: line)
        guard count >= openingLength else { return false }
        let text = line as NSString
        for index in count..<text.length {
            switch text.character(at: index) {
            case 0x20, 0x09, 0x0A, 0x0D: break
            default: return false
            }
        }
        return true
    }
}
