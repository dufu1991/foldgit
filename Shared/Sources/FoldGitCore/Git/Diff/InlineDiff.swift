import Foundation

/// Presentation-only differences. Offsets always describe complete graphemes in UTF-16.
enum InlineDiff {
    private static let maximumLineLength = 8_192
    private static let maximumMatrixSize = 65_536

    struct Budget {
        var remaining = 1_000_000

        mutating func consume(_ amount: Int) -> Bool {
            guard !Task.isCancelled, amount <= remaining else { return false }
            remaining -= amount
            return true
        }
    }

    private struct Token {
        let text: String
        let characters: Range<Int>
    }

    private struct Edit {
        let old: Range<Int>
        let new: Range<Int>
    }

    /// Keep positional pairing for oversized blocks, while aligning similar lines in ordinary edits.
    static func pair(_ old: [SideBySideDiff.Cell], _ new: [SideBySideDiff.Cell], budget: inout Budget) -> [(Int?, Int?)] {
        let positional = {
            (0..<max(old.count, new.count)).map { index in
                (index < old.count ? index : nil, index < new.count ? index : nil)
            }
        }
        guard !old.isEmpty, !new.isEmpty, old.count * new.count <= 4_096,
              old.count + new.count > 2,
              old.reduce(0, { $0 + $1.text.utf16.count }) + new.reduce(0, { $0 + $1.text.utf16.count }) <= 32_768,
              budget.consume(old.count + new.count) else { return positional() }

        let oldSignatures = old.map { signature($0.text) }
        let newSignatures = new.map { signature($0.text) }
        let width = new.count + 1
        var costs = Array(repeating: 0.0, count: (old.count + 1) * width)
        var scores = Array(repeating: 0.0, count: old.count * new.count)
        let gap = 0.6
        for i in 0...old.count { costs[i * width] = Double(i) * gap }
        for j in 0...new.count { costs[j] = Double(j) * gap }
        for i in 1...old.count {
            for j in 1...new.count {
                guard budget.consume(min(oldSignatures[i - 1].count, newSignatures[j - 1].count) + 1) else {
                    return positional()
                }
                let similarity = similarity(oldSignatures[i - 1], newSignatures[j - 1])
                let score = similarity >= 0.3 ? similarity : 0
                scores[(i - 1) * new.count + j - 1] = score
                costs[i * width + j] = min(
                    costs[(i - 1) * width + j - 1] + 1 - score,
                    min(costs[(i - 1) * width + j] + gap, costs[i * width + j - 1] + gap)
                )
            }
        }
        guard scores.contains(where: { $0 >= 0.3 }) else { return positional() }
        var result: [(Int?, Int?)] = []
        var i = old.count
        var j = new.count
        while i > 0 || j > 0 {
            if i > 0, j > 0,
               abs(costs[i * width + j] - (costs[(i - 1) * width + j - 1] + 1 - scores[(i - 1) * new.count + j - 1])) < 0.000_001 {
                result.append((i - 1, j - 1))
                i -= 1
                j -= 1
            } else if i > 0, abs(costs[i * width + j] - (costs[(i - 1) * width + j] + gap)) < 0.000_001 {
                result.append((i - 1, nil))
                i -= 1
            } else {
                result.append((nil, j - 1))
                j -= 1
            }
        }
        return result.reversed()
    }

    static func ranges(old: String, new: String, budget: inout Budget) -> (old: [Range<Int>], new: [Range<Int>]) {
        guard old != new, !old.isEmpty, !new.isEmpty,
              old.utf16.count <= maximumLineLength, new.utf16.count <= maximumLineLength,
              budget.consume(old.utf16.count + new.utf16.count) else { return ([], []) }
        // Unrelated replacement lines retain only their whole-line background.
        guard new.contains(old) || old.contains(new) || similarity(signature(old), signature(new)) >= 0.3 else { return ([], []) }
        let oldCharacters = Array(old)
        let newCharacters = Array(new)
        let oldTokens = tokens(oldCharacters)
        let newTokens = tokens(newCharacters)
        let tokenEdits = edits(old: oldTokens.map(\.text), new: newTokens.map(\.text), budget: &budget)
        let oldOffsets = offsets(oldCharacters)
        let newOffsets = offsets(newCharacters)
        let characterRange = { (range: Range<Int>, tokens: [Token], count: Int) in
            let start = range.lowerBound < tokens.count ? tokens[range.lowerBound].characters.lowerBound : count
            let end = range.upperBound < tokens.count ? tokens[range.upperBound].characters.lowerBound : count
            return start..<end
        }
        var oldRanges: [Range<Int>] = []
        var newRanges: [Range<Int>] = []
        for edit in tokenEdits {
            let oldRange = characterRange(edit.old, oldTokens, oldCharacters.count)
            let newRange = characterRange(edit.new, newTokens, newCharacters.count)
            let oldPart = String(oldCharacters[oldRange])
            let newPart = String(newCharacters[newRange])
            let hasCommonEdge = !oldPart.isEmpty && !newPart.isEmpty
                && (oldPart.first == newPart.first || oldPart.last == newPart.last)
            let refined = hasCommonEdge || similarity(signature(oldPart), signature(newPart)) >= 0.5
                ? edits(old: Array(oldCharacters[oldRange]), new: Array(newCharacters[newRange]), budget: &budget)
                : [Edit(old: 0..<oldRange.count, new: 0..<newRange.count)]
            for change in refined {
                if !change.old.isEmpty {
                    oldRanges.append(oldOffsets[oldRange.lowerBound + change.old.lowerBound]..<oldOffsets[oldRange.lowerBound + change.old.upperBound])
                }
                if !change.new.isEmpty {
                    newRanges.append(newOffsets[newRange.lowerBound + change.new.lowerBound]..<newOffsets[newRange.lowerBound + change.new.upperBound])
                }
            }
        }
        return (oldRanges, newRanges)
    }

    private static func signature(_ text: String) -> Set<String> {
        let characters = Array(text.trimmingCharacters(in: .whitespaces))
        guard characters.count > 1 else { return Set(characters.map(String.init)) }
        return Set(characters.map(String.init) + zip(characters, characters.dropFirst()).map { String($0) + String($1) })
    }

    private static func similarity(_ old: Set<String>, _ new: Set<String>) -> Double {
        guard !old.isEmpty || !new.isEmpty else { return 1 }
        let smaller = old.count < new.count ? old : new
        let larger = old.count < new.count ? new : old
        let common = smaller.reduce(0) { $0 + (larger.contains($1) ? 1 : 0) }
        return 2 * Double(common) / Double(old.count + new.count)
    }

    private static func tokens(_ characters: [Character]) -> [Token] {
        let kind = { (character: Character) in
            if character.isWhitespace { return 0 }
            let isIdentifier = character.isASCII
                && (character.isLetter || character.isNumber || character == "_" || character == "-")
            return isIdentifier ? 1 : 2
        }
        var result: [Token] = []
        var start = 0
        while start < characters.count {
            var end = start + 1
            let group = kind(characters[start])
            while group != 2, end < characters.count, kind(characters[end]) == group { end += 1 }
            result.append(Token(text: String(characters[start..<end]), characters: start..<end))
            start = end
        }
        return result
    }

    private static func offsets(_ characters: [Character]) -> [Int] {
        var result = [0]
        for character in characters { result.append(result.last! + character.utf16.count) }
        return result
    }

    /// A bounded LCS pass; common edges are removed before allocating its matrix.
    private static func edits<Element: Equatable>(old: [Element], new: [Element], budget: inout Budget) -> [Edit] {
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var oldEnd = old.count
        var newEnd = new.count
        while oldEnd > prefix, newEnd > prefix, old[oldEnd - 1] == new[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        guard prefix < oldEnd || prefix < newEnd else { return [] }
        let fallback = [Edit(old: prefix..<oldEnd, new: prefix..<newEnd)]
        guard prefix < oldEnd, prefix < newEnd else { return fallback }
        let height = oldEnd - prefix + 1
        let width = newEnd - prefix + 1
        guard height * width <= maximumMatrixSize, budget.consume(height * width) else { return fallback }
        var lengths = Array(repeating: 0, count: height * width)
        for i in stride(from: height - 2, through: 0, by: -1) {
            for j in stride(from: width - 2, through: 0, by: -1) {
                lengths[i * width + j] = old[prefix + i] == new[prefix + j]
                    ? lengths[(i + 1) * width + j + 1] + 1
                    : max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
            }
        }
        var result: [Edit] = []
        var i = 0
        var j = 0
        var oldStart = 0
        var newStart = 0
        while i < height - 1 || j < width - 1 {
            if i < height - 1, j < width - 1, old[prefix + i] == new[prefix + j] {
                if oldStart != i || newStart != j {
                    result.append(Edit(old: (prefix + oldStart)..<(prefix + i), new: (prefix + newStart)..<(prefix + j)))
                }
                i += 1
                j += 1
                oldStart = i
                newStart = j
            } else if i < height - 1, j == width - 1 || lengths[(i + 1) * width + j] >= lengths[i * width + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        if oldStart != i || newStart != j {
            result.append(Edit(old: (prefix + oldStart)..<(prefix + i), new: (prefix + newStart)..<(prefix + j)))
        }
        return result
    }
}
