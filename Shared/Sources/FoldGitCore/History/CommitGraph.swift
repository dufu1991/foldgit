public struct CommitGraph: Sendable {
    public init() {
    }

    public static let colorCount = 8

    /// Place the working tree immediately before its actual parent, preserving passing lanes.
    public func positionedHistory(_ commits: [Commit], headHash: String?, showsWorkingTree: Bool) -> [PositionedCommit] {
        guard showsWorkingTree else { return positionedCommits(commits) }
        var history = commits
        let index = headHash.flatMap { head in commits.firstIndex { $0.hash == head } } ?? 0
        let workingTree = Commit(hash: Log.notCommitted.id, parentHashes: headHash.map { [$0] } ?? [],
                                 author: "", authorEmail: "", authorDate: "", title: "", body: "", branches: [], tags: [])
        history.insert(workingTree, at: index)
        return positionedCommits(history)
    }

    private struct Lane: Equatable {
        let target: String
        let colorIndex: Int
    }

    public func positionedCommits(_ commits: [Commit]) -> [PositionedCommit] {
        let visibleHashes = Set(commits.map(\.hash))
        var lanes: [Lane?] = []
        var nextColor = 0
        var result: [PositionedCommit] = []
        result.reserveCapacity(commits.count)

        for (row, commit) in commits.enumerated() {
            let incomingColumn = lanes.firstIndex { $0?.target == commit.hash }
            let column: Int
            let colorIndex: Int
            if let incomingColumn, let lane = lanes[incomingColumn] {
                column = incomingColumn
                colorIndex = lane.colorIndex
            } else {
                column = lanes.firstIndex { $0 == nil } ?? lanes.count
                colorIndex = allocateColor(lanes: lanes, nextColor: &nextColor)
                if column == lanes.count {
                    lanes.append(nil)
                }
            }

            // Reserve each live lane until its target commit is reached.
            var segments = lanes.enumerated().compactMap { index, lane -> CommitGraphSegment? in
                guard let lane else { return nil }
                let reachesCommit = lane.target == commit.hash
                return CommitGraphSegment(
                    fromColumn: index, toColumn: reachesCommit ? column : index,
                    start: .top, end: reachesCommit ? .node : .bottom,
                    colorIndex: lane.colorIndex
                )
            }
            for index in lanes.indices where lanes[index]?.target == commit.hash {
                lanes[index] = nil
            }
            lanes[column] = nil
            var hasMissingParent = false

            for (parentIndex, hash) in commit.parentHashes.filter({ !$0.isEmpty }).enumerated() {
                guard visibleHashes.contains(hash) else {
                    hasMissingParent = true
                    continue
                }
                let parentColumn: Int
                let parentColor: Int
                // Keep edges to a shared parent separate until they reach its node.
                if parentIndex == 0 {
                    parentColumn = column
                    parentColor = colorIndex
                } else {
                    parentColumn = ((column + 1)..<lanes.count).first(where: { lanes[$0] == nil }) ?? lanes.count
                    parentColor = allocateColor(lanes: lanes, reserving: colorIndex, nextColor: &nextColor)
                }
                let lane = Lane(target: hash, colorIndex: parentColor)
                if parentColumn == lanes.count {
                    lanes.append(lane)
                } else {
                    lanes[parentColumn] = lane
                }
                segments.append(CommitGraphSegment(
                    fromColumn: column, toColumn: parentColumn,
                    start: .node, end: .bottom, colorIndex: parentColor
                ))
            }

            if hasMissingParent {
                segments.append(CommitGraphSegment(
                    fromColumn: column, toColumn: column, start: .node, end: .boundary,
                    colorIndex: colorIndex, isBoundary: true
                ))
            }
            result.append(PositionedCommit(
                commit: commit, column: column, row: row, colorIndex: colorIndex, segments: segments
            ))
            while lanes.last == .some(nil) {
                lanes.removeLast()
            }
        }
        return result
    }

    private func allocateColor(lanes: [Lane?], reserving colorIndex: Int? = nil, nextColor: inout Int) -> Int {
        var used = Set(lanes.compactMap { $0?.colorIndex }.map { $0 % Self.colorCount })
        if let colorIndex {
            used.insert(colorIndex % Self.colorCount)
        }
        for _ in 0..<Self.colorCount {
            let candidate = nextColor
            nextColor += 1
            if !used.contains(candidate % Self.colorCount) {
                return candidate
            }
        }
        let candidate = nextColor
        nextColor += 1
        return candidate
    }
}

public struct CommitGraphSegment: Equatable, Sendable {
    public init(fromColumn: Int, toColumn: Int, start: Position, end: Position, colorIndex: Int, isBoundary: Bool = false) {
        self.fromColumn = fromColumn
        self.toColumn = toColumn
        self.start = start
        self.end = end
        self.colorIndex = colorIndex
        self.isBoundary = isBoundary
    }

    public enum Position: Equatable, Sendable {
        case top, node, bottom, boundary
    }

    public let fromColumn: Int
    public let toColumn: Int
    public let start: Position
    public let end: Position
    public let colorIndex: Int
    public var isBoundary = false
}

public struct PositionedCommit: Identifiable, Sendable {
    public init(commit: Commit, column: Int, row: Int, colorIndex: Int, segments: [CommitGraphSegment]) {
        self.commit = commit
        self.column = column
        self.row = row
        self.colorIndex = colorIndex
        self.segments = segments
    }

    public var id: String { commit.hash }
    public let commit: Commit
    public let column: Int
    public let row: Int
    public let colorIndex: Int
    public let segments: [CommitGraphSegment]

    public var columnCount: Int {
        max(column, segments.map { max($0.fromColumn, $0.toColumn) }.max() ?? column) + 1
    }
}
