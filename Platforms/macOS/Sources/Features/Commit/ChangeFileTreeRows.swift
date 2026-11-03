import SwiftUI

/// Keeps the file sections flat so their diff bodies retain the full available width.
struct ChangeFileTreeRows<FileContent: View>: View {
    let tree: ChangeFileTree
    @Binding var collapsedDirectories: Set<String>
    var actionImageSystemName = "plus"
    var actionHelp = String(localized: "Stage This Directory")
    var onSelectDirectory: ((String) -> Void)? = nil
    var showsDirectoryActions = true
    @ViewBuilder var fileContent: (ChangeFileTree.Row) -> FileContent

    var body: some View {
        ForEach(tree.visibleRows(collapsedDirectories: collapsedDirectories)) { row in
            if row.isDirectory {
                directoryRow(row)
            } else {
                fileContent(row)
            }
        }
    }

    private func directoryRow(_ row: ChangeFileTree.Row) -> some View {
        let isExpanded = !collapsedDirectories.contains(row.path)
        return HStack(spacing: 4) {
            if showsDirectoryActions {
                Button {
                    onSelectDirectory?(row.path)
                } label: {
                    Image(systemName: actionImageSystemName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .help(actionHelp)
                .accessibilityLabel(Text(verbatim: actionHelp))
                .accessibilityIdentifier("changeDirectoryAction-" + row.path)
                .disabled(onSelectDirectory == nil)
            }

            Button {
                if isExpanded {
                    collapsedDirectories.insert(row.path)
                } else {
                    collapsedDirectories.remove(row.path)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 16, height: 16)
                        .foregroundStyle(.secondary)
                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .foregroundStyle(.secondary)
                    Text(verbatim: row.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .font(.body)
                .frame(minHeight: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .textSelection(.disabled)
            .help(row.path)
            .accessibilityLabel(Text(verbatim: row.path))
            .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
            .accessibilityHint(isExpanded ? Text("Collapse Folder") : Text("Expand Folder"))
            .accessibilityIdentifier("changeDirectory-" + row.path)
        }
        .padding(.leading, CGFloat(row.depth) * 16 + 3)
        .stageLandingRow(path: row.path, isCollapsedDirectory: !isExpanded)
    }
}

extension EnvironmentValues {
    /// Files that just moved into this change pane by staging or unstaging.
    @Entry var stageLandingPaths: Set<String> = []
}

extension View {
    /// Briefly tints a row whose file just moved into its pane. A collapsed folder stands in for the files it hides;
    /// expanded folders stay plain, since the file's own row shows the move.
    func stageLandingRow(path: String, isCollapsedDirectory: Bool = false) -> some View {
        modifier(StageLandingRowModifier(path: path, isCollapsedDirectory: isCollapsedDirectory))
    }
}

private struct StageLandingRowModifier: ViewModifier {
    @Environment(\.stageLandingPaths) private var paths
    var path: String
    var isCollapsedDirectory: Bool

    func body(content: Content) -> some View {
        let hasLanded = isCollapsedDirectory
            ? paths.contains { $0.hasPrefix(path + "/") }
            : paths.contains(path)
        content.stageLandingTint(hasLanded)
    }
}

extension View {
    // Rows paint an opaque background, so the tint sits on top of it.
    func stageLandingTint(_ isOn: Bool) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(isOn ? 0.18 : 0))
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.4), value: isOn)
    }

    /// Scrolls only as far as needed to show the row files just landed on.
    func scrollsToStageLanding(_ target: AnyHashable?, with proxy: ScrollViewProxy) -> some View {
        onChange(of: target) { _, target in
            guard let target else { return }
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(target) }
        }
    }
}

struct ChangeFileLayoutPicker: View {
    @Binding var layout: ChangeFileLayout

    var body: some View {
        Picker("Changed File Display", selection: $layout) {
            ForEach(ChangeFileLayout.allCases, id: \.self) { layout in
                Text(layout.title).tag(layout)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("Changed File Display")
        .accessibilityIdentifier("changeFileLayoutPicker")
    }
}
