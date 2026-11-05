import AppKit
import FoldGitCore
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
            if showsDirectoryActions && onSelectDirectory != nil {
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

/// Selection and row actions for one change pane. File rows read it to support selection, menus, and dragging.
struct ChangeRowContext {
    var directory: URL
    var isStaged: Bool
    var selection: Set<String>
    var select: (String) -> Void
    /// Stages or unstages the given paths; `nil` while staging is unavailable.
    var stage: (([String]) -> Void)?
    /// Asks to discard the given unstaged paths; `nil` in the staged pane or while unavailable.
    var discard: (([String]) -> Void)?
    var discardChunk: ((FileDiff, Chunk) -> Void)?

    /// A menu acts on the whole selection when the clicked row is part of it, otherwise on that row alone.
    func targets(for path: String) -> [String] {
        selection.contains(path) ? selection.sorted() : [path]
    }
}

extension EnvironmentValues {
    @Entry var changeRowContext: ChangeRowContext?
}

/// The drag payload that moves files between the unstaged and staged panes of one repository.
enum ChangeDragPayload {
    private static let marker = "foldgit-change-files"

    static func encode(paths: [String], isStaged: Bool, directory: URL) -> String {
        ([marker, directory.path, isStaged ? "staged" : "unstaged"] + paths).joined(separator: "\n")
    }

    /// The paths of a drag that started in the other pane of `directory`; `nil` for anything else.
    static func decode(_ payload: String, droppingInto staged: Bool, directory: URL) -> [String]? {
        let lines = payload.components(separatedBy: "\n")
        guard lines.count > 3, lines[0] == marker, lines[1] == directory.path,
              lines[2] == (staged ? "unstaged" : "staged") else { return nil }
        return Array(lines.dropFirst(3)).filter { !$0.isEmpty }
    }
}

extension View {
    /// Makes a file row selectable, double-clickable, draggable, and gives it the change file menu.
    func changeFileRow(path: String) -> some View {
        modifier(ChangeFileRowModifier(path: path))
    }
}

private struct ChangeFileRowModifier: ViewModifier {
    @Environment(\.changeRowContext) private var context
    let path: String

    func body(content: Content) -> some View {
        if let context {
            let isSelected = context.selection.contains(path)
            content
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(isSelected ? 0.2 : 0))
                        .allowsHitTesting(false)
                }
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    context.stage?([path])
                })
                .simultaneousGesture(TapGesture().onEnded { context.select(path) })
                .contextMenu { ChangeFileMenu(context: context, path: path) }
                .onDrag {
                    let paths = context.stage == nil ? [path] : context.targets(for: path)
                    return NSItemProvider(object: ChangeDragPayload.encode(paths: paths, isStaged: context.isStaged,
                                                                          directory: context.directory) as NSString)
                }
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            content
        }
    }
}

private struct ChangeFileMenu: View {
    let context: ChangeRowContext
    let path: String

    var body: some View {
        let targets = context.targets(for: path)
        let urls = targets.map { context.directory.appendingPathComponent($0) }
        if let stage = context.stage {
            Button(context.isStaged ? "Unstage" : "Stage", systemImage: context.isStaged ? "minus" : "plus") {
                stage(targets)
            }
        }
        if let discard = context.discard {
            Button("Discard Changes", systemImage: "arrow.uturn.backward") { discard(targets) }
        }
        if context.stage != nil || context.discard != nil { Divider() }
        Button("Show in Finder", systemImage: "folder") {
            let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            NSWorkspace.shared.activateFileViewerSelecting(existing.isEmpty ? [context.directory] : existing)
        }
        Button("Copy Path", systemImage: "doc.on.doc") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        }
        Button("Open", systemImage: "arrow.up.right") {
            for url in urls where FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
        }
    }
}
