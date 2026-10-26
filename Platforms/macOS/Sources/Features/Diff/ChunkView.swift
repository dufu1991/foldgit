import FoldGitCore
import SwiftUI

struct ChunkView: View {
    @AppStorage(PreferenceKey.diffLayout.rawValue) private var layout = DiffLayout.automatic
    @AppStorage(PreferenceKey.codeFontSize.rawValue) private var fontSize = AppPreferences.defaultCodeFontSize
    @AppStorage(PreferenceKey.wrapLongLines.rawValue) private var wraps = false
    @State private var viewportWidth: CGFloat = 0
    @State private var prepared: PreparedDiff?
    let chunk: Chunk
    let filePath: String

    private var resolvedLayout: DiffLayout { layout.resolved(for: viewportWidth) }

    private struct PreparedDiff {
        let raw: String
        let diff: SideBySideDiff
    }

    var body: some View {
        Group {
            if let prepared, prepared.raw == chunk.raw {
                if resolvedLayout == .sideBySide, prepared.diff.isSupported {
                    SideBySideChunkView(diff: prepared.diff, filePath: filePath)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        if resolvedLayout == .sideBySide {
                            Text("Combined merge diffs use unified layout.").font(.caption).foregroundStyle(.secondary)
                        }
                        unified(cells: prepared.diff.unifiedCells)
                    }
                }
            } else {
                ProgressView().controlSize(.small).frame(height: 28)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .task(id: chunk.raw) {
            guard prepared?.raw != chunk.raw else { return }
            let chunk = chunk
            let calculation = Task.detached(priority: .userInitiated) { SideBySideDiff(chunk: chunk) }
            let diff = await withTaskCancellationHandler {
                await calculation.value
            } onCancel: {
                calculation.cancel()
            }
            guard !Task.isCancelled else { return }
            prepared = PreparedDiff(raw: chunk.raw, diff: diff)
        }
    }

    private func unified(cells: [SideBySideDiff.Cell]) -> some View {
        let rows = cells.map { SideBySideDiff.Row(old: nil, new: $0) }
        let layout = DiffCodeLayout(rows: rows, columnWidth: max(120, viewportWidth), fontSize: fontSize, wraps: wraps)
        return DiffCodeColumn(cells: cells.map(Optional.some), filePath: filePath, layout: layout, lineCounts: layout.newLineCounts)
            .frame(height: layout.height + 8 + (wraps ? 0 : 16))
    }
}

#Preview {
    ChunkView(chunk: Chunk(raw: "@@ -1 +1 @@\n-let value = 1\n+let value = 2"), filePath: "Example.swift")
}
