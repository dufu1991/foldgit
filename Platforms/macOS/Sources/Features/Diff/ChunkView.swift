import FoldGitCore
import SwiftUI

struct ChunkView: View {
    @Environment(\.diffViewportWidth) private var listViewportWidth
    @AppStorage(PreferenceKey.diffLayout.rawValue) private var layout = DiffLayout.automatic
    @AppStorage(PreferenceKey.codeFontSize.rawValue) private var fontSize = AppPreferences.defaultCodeFontSize
    @AppStorage(PreferenceKey.wrapLongLines.rawValue) private var wraps = false
    @State private var viewportWidth: CGFloat = 0
    let chunk: Chunk
    let filePath: String

    private var availableWidth: CGFloat { listViewportWidth > 0 ? listViewportWidth : viewportWidth }
    private var resolvedLayout: DiffLayout { layout.resolved(for: availableWidth) }

    var body: some View {
        Group {
            if resolvedLayout == .sideBySide, chunk.presentation.isSupported {
                SideBySideChunkView(diff: chunk.presentation, filePath: filePath, availableWidth: availableWidth)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if resolvedLayout == .sideBySide {
                        Text("Combined merge diffs use unified layout.").font(.caption).foregroundStyle(.secondary)
                    }
                    unified(cells: chunk.presentation.unifiedCells)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
            if listViewportWidth == 0 { viewportWidth = $0 }
        }
    }

    private func unified(cells: [SideBySideDiff.Cell]) -> some View {
        let rows = cells.map { SideBySideDiff.Row(old: nil, new: $0) }
        let layout = DiffCodeLayout(rows: rows, columnWidth: max(120, availableWidth), fontSize: fontSize, wraps: wraps)
        return DiffCodeColumn(cells: cells.map(Optional.some), filePath: filePath, layout: layout, lineCounts: layout.newLineCounts)
            .frame(height: layout.height + 8 + (wraps ? 0 : 16))
    }
}

extension EnvironmentValues {
    /// Measure once at the file list, so newly visible hunks use the final layout immediately.
    @Entry var diffViewportWidth: CGFloat = 0
}

#Preview {
    ChunkView(chunk: Chunk(raw: "@@ -1 +1 @@\n-let value = 1\n+let value = 2"), filePath: "Example.swift")
}
