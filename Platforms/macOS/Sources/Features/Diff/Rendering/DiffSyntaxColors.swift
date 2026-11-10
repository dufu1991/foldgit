import FoldGitCore
import SwiftUI

/// Syntax colors for the rows of one file diff, tokenized from the complete old and new files
/// so constructs that start outside a hunk still color the rows inside it.
struct DiffSyntaxColors: Sendable {
    let before: [Int: SyntaxLine]
    let after: [Int: SyntaxLine]

    /// Returns nil for rows whose text no longer matches, so older colors can stay on screen while new ones load.
    func spans(for cell: SideBySideDiff.Cell?, oldSide: Bool, prefixLength: Int = 0) -> [SyntaxColorSpan]? {
        guard let cell else { return nil }
        let lines = oldSide || cell.oldLineNumber != nil ? before : after
        guard let number = cell.oldLineNumber ?? cell.lineNumber, let line = lines[number],
              cell.text.utf16.dropFirst(prefixLength).elementsEqual(line.text.utf16) else { return nil }
        return line.spans
    }

    static func load(file: FileDiff, directory: URL, context: DiffFileContext, isDark: Bool) async -> Self {
        let (oldLines, newLines) = lines(in: file.chunks)
        async let before = loadSide(directory: directory, path: file.fromFilePath,
                                    version: context.version(for: file, oldSide: true), isDark: isDark, matching: oldLines)
        async let after = loadSide(directory: directory, path: file.toFilePath,
                                   version: context.version(for: file, oldSide: false), isDark: isDark, matching: newLines)
        return await Self(before: before, after: after)
    }

    /// Colors a self-contained hunk, such as the Settings preview, from its own lines.
    static func snippet(_ chunk: Chunk, path: String, isDark: Bool) async -> Self {
        let (oldLines, newLines) = lines(in: [chunk])
        func source(_ lines: [Int: String]) -> String {
            (1...max(1, lines.keys.max() ?? 1)).map { lines[$0] ?? "" }.joined(separator: "\n")
        }
        async let before = highlight(source(oldLines), path: path, isDark: isDark, matching: oldLines)
        async let after = highlight(source(newLines), path: path, isDark: isDark, matching: newLines)
        return await Self(before: before, after: after)
    }

    private static func lines(in chunks: [Chunk]) -> (old: [Int: String], new: [Int: String]) {
        var old: [Int: String] = [:]
        var new: [Int: String] = [:]
        for chunk in chunks where chunk.presentation.isSupported {
            for row in chunk.presentation.rows {
                if let cell = row.old, let number = cell.lineNumber { old[number] = cell.text }
                if let cell = row.new, let number = cell.lineNumber { new[number] = cell.text }
            }
        }
        return (old, new)
    }

    private static func loadSide(directory: URL, path: String, version: GitFileVersion,
                                 isDark: Bool, matching lines: [Int: String]) async -> [Int: SyntaxLine] {
        guard !lines.isEmpty, !Task.isCancelled, FileSyntaxHighlighter.shared.language(for: path) != nil else { return [:] }
        let content: FileContentSnapshot.Content
        if version == .workingTree {
            let url = directory.appendingPathComponent(path)
            let task = Task.detached(priority: .userInitiated) {
                try FileContentReader.read(url, allowLarge: false).content
            }
            guard let snapshot = try? await withTaskCancellationHandler(operation: { try await task.value },
                                                                        onCancel: { task.cancel() }) else { return [:] }
            content = snapshot
        } else {
            guard let data = try? await GitFileContent.read(at: directory, path: path, version: version,
                                                             maximumBytes: FileContentReader.automaticLimit),
                  let decoded = try? FileContentReader.decode(data, plain: false) else { return [:] }
            content = decoded
        }
        guard case .text(let source, plain: false, layout: _) = content else { return [:] }
        return await highlight(source, path: path, isDark: isDark, matching: lines)
    }

    private static func highlight(_ source: String, path: String, isDark: Bool,
                                  matching lines: [Int: String]) async -> [Int: SyntaxLine] {
        let highlighter = FileSyntaxHighlighter.shared
        guard !lines.isEmpty, let language = highlighter.language(for: path) else { return [:] }
        return (try? await highlighter.spansByLine(in: source, language: language, isDark: isDark, matching: lines)) ?? [:]
    }
}

struct DiffSyntaxContent<Content: View>: View {
    @Environment(\.folder) private var folder
    @Environment(\.diffFileContext) private var context
    @Environment(\.diffFileRefreshID) private var refreshID
    @Environment(\.colorScheme) private var colorScheme
    @State private var result: (request: Request, colors: DiffSyntaxColors)?
    let file: FileDiff
    @ViewBuilder let content: (DiffSyntaxColors?) -> Content

    private struct Request: Hashable {
        let folder: URL?
        let context: DiffFileContext?
        let patch: String
        let refreshID: Int
        let isDark: Bool
    }

    var body: some View {
        let request = Request(folder: folder, context: context, patch: file.raw, refreshID: refreshID,
                              isDark: colorScheme == .dark)
        // Keep the previous colors during a refresh; rows whose text changed are skipped until the new colors arrive.
        content(result?.request.isDark == request.isDark ? result?.colors : nil)
            .task(id: request) {
                guard let folder = request.folder, let context = request.context else {
                    result = nil
                    return
                }
                let colors = await DiffSyntaxColors.load(file: file, directory: folder, context: context, isDark: request.isDark)
                guard !Task.isCancelled else { return }
                result = (request, colors)
            }
    }
}
