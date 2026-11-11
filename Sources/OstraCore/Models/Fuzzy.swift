import Foundation

/// Scores how well a search query matches a piece of text.
///
/// Higher is better, and nil means no match. The order of preference: the
/// text starts with the query, a word starts with it, the text contains it,
/// and last, its letters appear in order with gaps (so `wsp` finds
/// `WorkspacePanel`). A query of several words matches when every word does.
public enum Fuzzy {
    public static func score(_ query: String, in text: String) -> Int? {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return 0 }
        let original = Array(text)
        var haystack = Array(text.lowercased())
        // Lowercasing can change the length in a few scripts. Boundaries
        // need the two arrays in step, so fall back to the original.
        if haystack.count != original.count { haystack = original }
        guard !haystack.isEmpty else { return nil }

        var total = 0
        for word in words {
            guard let score = score(word: Array(word), in: haystack, original: original) else { return nil }
            total += score
        }
        // Between equal matches, the shorter text is the closer one.
        return total - min(haystack.count, 200) / 8
    }

    private static func score(word: [Character], in text: [Character], original: [Character]) -> Int? {
        guard word.count <= text.count else { return nil }

        if let position = firstRange(of: word, in: text) {
            if position == 0 { return 1000 }
            if isBoundary(original, at: position) { return 800 - min(position, 100) }
            return 600 - min(position, 100)
        }

        // Letters in order. Runs and word starts score; gaps cost.
        var score = 300
        var index = 0
        var previous = -2
        for character in word {
            guard let found = text[index...].firstIndex(of: character) else { return nil }
            if found == previous + 1 {
                score += 12
            } else {
                score -= min(found - index, 12)
                if isBoundary(original, at: found) { score += 8 }
            }
            previous = found
            index = found + 1
        }
        return max(score, 1)
    }

    private static func firstRange(of word: [Character], in text: [Character]) -> Int? {
        guard let first = word.first else { return 0 }
        var start = 0
        while start + word.count <= text.count {
            guard let candidate = text[start...].firstIndex(of: first), candidate + word.count <= text.count else {
                return nil
            }
            if Array(text[candidate..<(candidate + word.count)]) == word { return candidate }
            start = candidate + 1
        }
        return nil
    }

    /// True when the character at `index` starts a word: after a space or a
    /// separator, or where lowercase steps up to uppercase, as in `camelCase`.
    private static func isBoundary(_ text: [Character], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let before = text[index - 1]
        if before.isWhitespace || before.isPunctuation || before.isSymbol { return true }
        return text[index].isUppercase && before.isLowercase
    }

    /// A short excerpt of `text` around the first place `query` appears.
    public static func snippet(of text: String, around query: String, radius: Int = 48) -> String? {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty, let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return nil
        }
        let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: radius * 2, limitedBy: text.endIndex) ?? text.endIndex
        var excerpt = text[start..<end]
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if start > text.startIndex { excerpt = "…" + excerpt }
        if end < text.endIndex { excerpt += "…" }
        return excerpt
    }
}
