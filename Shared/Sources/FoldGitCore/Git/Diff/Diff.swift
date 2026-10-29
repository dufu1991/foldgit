import Foundation

public struct Diff: Hashable, Sendable {
    public var fileDiffs: [FileDiff]
    public var raw: String

    public init(raw: String) throws {
        self.raw = raw
        guard !raw.isEmpty else {
            fileDiffs = []
            return
        }
        fileDiffs = try ("\n" + raw).split(separator: "\ndiff").filter { !$0.hasPrefix("\n* Unmerged path") }.map { fileDiffRaw in
            let fileDiff = try FileDiff(raw: String("diff" + fileDiffRaw))
            return fileDiff
        }
    }

    public func updateAll(stage: Bool) -> Self {
        let newFileDiffs = fileDiffs.map { fileDiff in
            fileDiff.updateAll(stage: stage)
        }
        var new = self
        new.fileDiffs = newFileDiffs
        return new
    }

    public func updateFileDiffStage(_ fileDiff: FileDiff, stage: Bool) -> Self {
        let fileDiffIndex = fileDiffs.firstIndex { $0.id == fileDiff.id }
        guard let fileDiffIndex  else { return self }
        var new = self
        new.fileDiffs[fileDiffIndex] = fileDiff.updateAll(stage: stage)
        return new
    }

    public func updateChunkStage(_ chunk: Chunk, in fileDiff: FileDiff, stage: Bool) -> Self {
        let fileDiffIndex = fileDiffs.firstIndex { $0.id == fileDiff.id }
        guard let fileDiffIndex  else { return self }
        let chunkIndex = fileDiffs[fileDiffIndex].chunks.firstIndex { $0.id == chunk.id }
        guard let chunkIndex else { return self }
        var new = self
        var newChunk = chunk
        newChunk.stage = stage
        new.fileDiffs[fileDiffIndex].chunks[chunkIndex] = newChunk
        return new
    }

    /// Whole files use pathspecs; partially selected files become a patch that Git rejects if the index moved.
    public func indexSelection(staging: Bool) -> IndexSelection {
        var paths: [String] = []
        var patches: [String] = []
        for fileDiff in fileDiffs {
            let selected = fileDiff.chunks.filter { $0.stage == staging }
            let isCombined = fileDiff.header.hasPrefix("diff --cc ") || fileDiff.header.hasPrefix("diff --combined ")
            if fileDiff.chunks.isEmpty {
                if fileDiff.stage == staging { paths.append(fileDiff.toFilePath) }
            } else if selected.count == fileDiff.chunks.count || (isCombined && !selected.isEmpty) {
                paths.append(fileDiff.toFilePath)
            } else if !selected.isEmpty {
                let hunks = selected.map { chunk in
                    var lines = chunk.raw.split(separator: "\n", omittingEmptySubsequences: false)
                    while lines.last?.isEmpty == true { lines.removeLast() }
                    return lines.joined(separator: "\n")
                }
                patches.append(([fileDiff.header] + fileDiff.extendedHeaderLines + fileDiff.fromFileToFileLines + hunks).joined(separator: "\n"))
            }
        }
        return IndexSelection(paths: paths, patch: patches.joined(separator: "\n"))
    }
}

public struct IndexSelection: Equatable, Sendable {
    public var paths: [String]
    public var patch: String
    public var isEmpty: Bool { paths.isEmpty && patch.isEmpty }
}

public struct FileDiff: Identifiable, Hashable, Sendable {
    /// The `diff` header names the file, so identity survives content refreshes.
    public var id: String { header }
    public let header: String

    /// Resolved once while parsing; rows and stage actions read paths on every update.
    public let fromFilePath: String
    public let toFilePath: String

    private static func resolvedPath(header: String, fromFileToFileLines: [String], prefix: String, fallback: Int) -> String {
        if let line = fromFileToFileLines.first(where: { $0.hasPrefix(prefix) }) {
            let path = String(line.dropFirst(prefix.count)).components(separatedBy: "\t")[0]
            if path != "/dev/null" { return GitPath.withoutPrefix(path) }
        }
        if header.hasPrefix("diff --cc ") { return GitPath.decode(String(header.dropFirst("diff --cc ".count))) }
        if header.hasPrefix("diff --combined ") { return GitPath.decode(String(header.dropFirst("diff --combined ".count))) }
        let raw = String(header.dropFirst("diff --git ".count))
        if raw.hasPrefix("\"") {
            let parts = raw.components(separatedBy: "\" \"")
            if parts.count == 2 { return GitPath.withoutPrefix(fallback == 0 ? parts[0] + "\"" : "\"" + parts[1]) }
        }
        if let separator = raw.range(of: " b/", options: .backwards) {
            return GitPath.withoutPrefix(fallback == 0 ? String(raw[..<separator.lowerBound]) : String(raw[separator.lowerBound...].dropFirst()))
        }
        return ""
    }

    public var filePathDisplay: String {
        if fromFilePath == toFilePath {
            return fromFilePath
        }
        if !fromFilePath.isEmpty && !toFilePath.isEmpty && fromFilePath != toFilePath {
            return fromFilePath + " => " + toFilePath
        }
        return ""
    }

    public let extendedHeaderLines: [String]
    public let fromFileToFileLines: [String]
    public let change: FileChange
    public var chunks: [Chunk]
    public var stage: Bool?
    public let raw: String

    private static func extractChunks(from lines: [String]) -> [String] {
        var chunks: [String] = []
        var currentChunk: String?

        for line in lines {
            if line.starts(with: "@@") {
                if let hunk = currentChunk {
                    chunks.append(hunk)
                }
                currentChunk = line
            } else {
                currentChunk?.append("\n" + line)
            }
        }

        if let lastHunk = currentChunk {
            chunks.append(lastHunk)
        }

        return chunks
    }

    public init(raw: String) throws {
        self.raw = raw
        let splited = raw.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        let firstLine = splited.first
        guard let firstLine else {
            throw GenericError(errorDescription: NSLocalizedString("Couldn't read the diff.", comment: ""))
        }
        header = firstLine
        let fromFileIndex = splited.firstIndex { $0.hasPrefix("--- ") }
        guard let fromFileIndex else {
            extendedHeaderLines = splited[1..<splited.endIndex].map { String($0) }
            fromFileToFileLines = []
            chunks = []
            fromFilePath = Self.resolvedPath(header: firstLine, fromFileToFileLines: [], prefix: "--- ", fallback: 0)
            toFilePath = Self.resolvedPath(header: firstLine, fromFileToFileLines: [], prefix: "+++ ", fallback: 1)
            change = FileChange(header: firstLine, extendedHeaderLines: extendedHeaderLines, hasHunks: false)
            return
        }
        extendedHeaderLines = splited[1..<fromFileIndex].map { String($0) }
        let toFileIndex = splited.indices.first { $0 > fromFileIndex && splited[$0].hasPrefix("+++ ") }
        guard let toFileIndex else {
            throw GenericError(errorDescription: NSLocalizedString("Couldn't read the changed file in the diff.", comment: ""))
        }
        fromFileToFileLines = splited[fromFileIndex...toFileIndex].map { String($0) }
        chunks = Self.extractChunks(from: splited).map { Chunk(raw: $0) }
        fromFilePath = Self.resolvedPath(header: firstLine, fromFileToFileLines: fromFileToFileLines, prefix: "--- ", fallback: 0)
        toFilePath = Self.resolvedPath(header: firstLine, fromFileToFileLines: fromFileToFileLines, prefix: "+++ ", fallback: 1)
        change = FileChange(header: firstLine, extendedHeaderLines: extendedHeaderLines, hasHunks: !chunks.isEmpty)
    }

    public func updateAll(stage: Bool) -> Self {
        guard !chunks.isEmpty else {
            var newSelf = self
            newSelf.stage = stage
            return newSelf
        }
        let newChunks = chunks.map { chunk in
            var newChunk = chunk
            newChunk.stage = stage
            return newChunk
        }
        var new = self
        new.chunks = newChunks
        return new
    }
}

public struct Chunk: Identifiable, Hashable, Sendable {
    public struct Line: Identifiable, Hashable, Sendable {
        public enum Kind: Sendable {
            case removed, added, unchanged, header
        }
        public var id: Int
        public var kind: Kind {
            switch raw.first {
            case "-":
                return .removed
            case "+":
                return .added
            case " ":
                return .unchanged
            case "@":
                return .header
            default:
                return .unchanged
            }
        }
        public var toFileLineNumber: Int?
        public var raw: String

        public init(id: Int, raw: String) {
            self.id = id
            self.raw = raw
        }
    }
    /// Hunk ranges are unique within a file; content changes keep the same view identity.
    public var id: String { String(raw.prefix { $0 != "\n" }) }
    public var lines: [Line]
    public var raw: String
    public var stage: Bool?

    public init(raw: String) {
        // The new-file start line is the number after "+" in "@@ -a,b +c,d @@".
        let start = raw.split(separator: "+", maxSplits: 1)[safe: 1]?
            .split(separator: " ", maxSplits: 1).first?.split(separator: ",", maxSplits: 1).first.flatMap { Int($0) }
        var nextLine = start
        self.raw = raw
        lines = raw.split(separator: "\n").enumerated().map { offset, text in
            var line = Line(id: offset, raw: String(text))
            if let number = nextLine, line.kind == .added || line.kind == .unchanged {
                line.toFileLineNumber = number
                nextLine = number + 1
            }
            return line
        }
    }
}
