import Foundation

public struct SideBySideDiff: Sendable {
    public struct Cell: Equatable, Sendable {
        public init(text: String, lineNumber: Int? = nil, kind: Chunk.Line.Kind, changedRanges: [Range<Int>] = []) {
            self.text = text
            self.lineNumber = lineNumber
            self.kind = kind
            self.changedRanges = changedRanges
        }

        public var text: String
        public var lineNumber: Int?
        public var kind: Chunk.Line.Kind
        /// UTF-16 ranges relative to `text`, with boundaries on complete graphemes.
        public var changedRanges: [Range<Int>]
    }

    public struct Row: Equatable, Sendable {
        public init(old: Cell? = nil, new: Cell? = nil) {
            self.old = old
            self.new = new
        }

        public var old: Cell?
        public var new: Cell?
    }

    public let header: String
    public let rows: [Row]
    public let unifiedCells: [Cell]
    public let isSupported: Bool

    public init(chunk: Chunk) {
        let lines = chunk.raw.components(separatedBy: "\n")
        header = lines.first ?? ""
        let ranges = header.split(separator: " ")
        isSupported = ranges.count >= 4 && ranges[0] == "@@" && ranges[3] == "@@"
        guard isSupported,
              let oldRange = ranges[1].dropFirst().split(separator: ",").first,
              let newRange = ranges[2].dropFirst().split(separator: ",").first,
              let oldStart = Int(oldRange),
              let newStart = Int(newRange) else {
            rows = []
            unifiedCells = chunk.lines.map { Cell(text: $0.raw, lineNumber: $0.toFileLineNumber, kind: $0.kind) }
            return
        }

        var oldLine = oldStart
        var newLine = newStart
        var result: [Row] = []
        var removed: [Cell] = []
        var added: [Cell] = []
        var oldAnnotation: Cell?
        var newAnnotation: Cell?
        var inlineBudget = InlineDiff.Budget()
        var pairingBudget = InlineDiff.Budget(remaining: 100_000)

        let flushChanges = {
            for (oldIndex, newIndex) in InlineDiff.pair(removed, added, budget: &pairingBudget) {
                var oldCell = oldIndex.map { removed[$0] }
                var newCell = newIndex.map { added[$0] }
                if let old = oldCell, let new = newCell {
                    let ranges = InlineDiff.ranges(old: old.text, new: new.text, budget: &inlineBudget)
                    oldCell?.changedRanges = ranges.old
                    newCell?.changedRanges = ranges.new
                }
                result.append(Row(old: oldCell, new: newCell))
            }
            if oldAnnotation != nil || newAnnotation != nil {
                result.append(Row(old: oldAnnotation, new: newAnnotation))
            }
            removed.removeAll(keepingCapacity: true)
            added.removeAll(keepingCapacity: true)
            oldAnnotation = nil
            newAnnotation = nil
        }

        for line in lines.dropFirst() {
            switch line.first {
            case "-":
                removed.append(Cell(text: String(line.dropFirst()), lineNumber: oldLine, kind: .removed))
                oldLine += 1
            case "+":
                added.append(Cell(text: String(line.dropFirst()), lineNumber: newLine, kind: .added))
                newLine += 1
            case "\\":
                // Keep end-of-file annotations with their side without advancing line numbers.
                let annotation = Cell(text: line, lineNumber: nil, kind: .header)
                if !added.isEmpty {
                    newAnnotation = annotation
                } else if !removed.isEmpty {
                    oldAnnotation = annotation
                } else {
                    result.append(Row(old: annotation, new: annotation))
                }
            default:
                guard !line.isEmpty else { continue }
                flushChanges()
                let text = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                result.append(Row(
                    old: Cell(text: text, lineNumber: oldLine, kind: .unchanged),
                    new: Cell(text: text, lineNumber: newLine, kind: .unchanged)
                ))
                oldLine += 1
                newLine += 1
            }
        }
        flushChanges()
        rows = result
        let oldRanges = Dictionary(uniqueKeysWithValues: result.compactMap { row -> (Int, [Range<Int>])? in
            guard let cell = row.old, cell.kind == .removed, let number = cell.lineNumber else { return nil }
            return (number, cell.changedRanges)
        })
        let newRanges = Dictionary(uniqueKeysWithValues: result.compactMap { row -> (Int, [Range<Int>])? in
            guard let cell = row.new, cell.kind == .added, let number = cell.lineNumber else { return nil }
            return (number, cell.changedRanges)
        })
        var oldNumber = oldStart
        var newNumber = newStart
        unifiedCells = chunk.lines.map { line in
            var ranges: [Range<Int>] = []
            var number: Int?
            switch line.kind {
            case .removed:
                ranges = oldRanges[oldNumber] ?? []
                oldNumber += 1
            case .added:
                ranges = newRanges[newNumber] ?? []
                number = newNumber
                newNumber += 1
            case .unchanged:
                if !line.raw.hasPrefix("\\") {
                    number = newNumber
                    oldNumber += 1
                    newNumber += 1
                }
            case .header:
                break
            }
            return Cell(text: line.raw, lineNumber: number, kind: line.kind,
                        changedRanges: ranges.map { ($0.lowerBound + 1)..<($0.upperBound + 1) })
        }
    }
}
