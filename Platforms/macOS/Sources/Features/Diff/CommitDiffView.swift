import FoldGitCore
import SwiftUI

struct CommitDiffView: View {
    @AppStorage(PreferenceKey.diffFileExpansion.rawValue) private var fileExpansion = AppPreferences.defaultDiffFileExpansion
    @Environment(\.folder) private var folder
    var selectionLogID: String
    var subSelectionLogID: String
    var showsComparisonControls = true
    /// Two selected commits are shown from the earlier one to the later one. Compare passes explicit sides instead.
    var ordersByHistory = true
    /// Changing this reloads the diff in place, for example after a fetch moved the compared references.
    var reloadID: UUID?

    @State private var base = ""
    @State private var target = ""
    @State private var isSwapped = false
    @State private var filesChanges: [ExpandableModel<FileDiff>] = []
    @State private var filesChangesIsEmpty = false
    @State private var isLoading = false
    @State private var shortstat = ""
    @State private var error: Error?

    private struct LoadKey: Hashable {
        var first: String
        var second: String
        var isSwapped: Bool
        var reloadID: UUID?
    }

    private var diffFileContext: DiffFileContext {
        DiffFileContext(old: version(of: base), new: version(of: target))
    }

    private func version(of revision: String) -> GitFileVersion {
        revision == Log.notCommitted.id ? .workingTree : .revision(revision)
    }

    var body: some View {
        ScrollView {
            if filesChangesIsEmpty && !isLoading {
                LazyVStack(alignment: .center) {
                    Label("No Changes", systemImage: "plusminus")
                        .foregroundStyle(.secondary)
                        .padding()
                        .padding()
                        .padding(.vertical, 40)
                }
            }
            FileDiffsView(expandableFileDiffs: $filesChanges)
                .environment(\.diffFileContext, diffFileContext)
                .padding(.horizontal)
                .opacity(isLoading && !filesChanges.isEmpty ? 0.45 : 1)
        }
        .overlay {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Loading Differences"))
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .scrollEdgeEffectStyle(.hard, for: .vertical)
        .safeAreaBar(edge: .bottom, spacing: 0, content: {
            VStack(spacing: 0) {
                PixelDivider()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        displayControls
                        if showsComparisonControls { comparisonControls }
                        statistics
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 10) {
                        displayControls
                        if showsComparisonControls { comparisonControls }
                        statistics
                    }
                }
                .font(.callout)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.horizontal)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            }
        })
        .onChange(of: [selectionLogID, subSelectionLogID]) { _, _ in
            isSwapped = false
        }
        .task(id: LoadKey(first: selectionLogID, second: subSelectionLogID, isSwapped: isSwapped, reloadID: reloadID)) {
            await reload()
        }
        .errorSheet($error, operation: "Load Differences")
    }

    private var displayControls: some View {
        DiffDisplayControls(onExpandAll: {
            filesChanges = filesChanges.settingExpansion(true)
        }, onCollapseAll: {
            filesChanges = filesChanges.settingExpansion(false)
        })
    }

    private var comparisonControls: some View {
        HStack(spacing: 8) {
            Text("Diff").foregroundStyle(.secondary)
            title(for: base)
                .lineLimit(1)
                .help(helpText(for: base))
            Text(verbatim: "→").foregroundStyle(.secondary)
            title(for: target)
                .lineLimit(1)
                .help(helpText(for: target))
            Button("Swap Commits") { isSwapped.toggle() }
                .fixedSize()
                .disabled(base.isEmpty || target.isEmpty)
                .accessibilityIdentifier("swapDiffCommits")
        }
    }

    private var statistics: some View {
        Text(shortstat)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `git diff <commit>` compares with the working tree, including unstaged edits, so the side is named that.
    private func title(for revision: String) -> Text {
        revision == Log.notCommitted.id ? Text("Working Tree") : Text(verbatim: Self.shortRevision(revision))
    }

    private func helpText(for revision: String) -> Text {
        revision == Log.notCommitted.id ? Text("Working Tree") : Text(verbatim: revision)
    }

    static func shortRevision(_ revision: String) -> String {
        let isHash = revision.count >= 40 && revision.allSatisfy(\.isHexDigit)
        return isHash ? String(revision.prefix(7)) : revision
    }

    private func reload() async {
        guard let folder, !selectionLogID.isEmpty, !subSelectionLogID.isEmpty else { return }
        isLoading = true
        defer { if !Task.isCancelled { isLoading = false } }
        do {
            var (older, newer) = (selectionLogID, subSelectionLogID)
            if ordersByHistory {
                (older, newer) = try await Self.chronological(selectionLogID, subSelectionLogID, in: folder)
            }
            if isSwapped { swap(&older, &newer) }
            let arguments = Self.diffArguments(base: older, target: newer)
            let raw = try await GitRuntime.run(RevisionDiffQuery(directory: folder, arguments: arguments))
            let changes = try await DiffLoading.expandableFileDiffs(raw: raw, preference: fileExpansion)
            let stat = try await GitRuntime.run(RevisionDiffQuery(directory: folder, arguments: arguments + ["--shortstat"]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
            base = older
            target = newer
            filesChanges = changes
            filesChangesIsEmpty = changes.isEmpty
            shortstat = stat.isEmpty ? String(localized: "No Changes") : GitSummary.shortStat(stat)
        } catch {
            guard !Task.isCancelled else { return }
            filesChanges = []
            filesChangesIsEmpty = false
            shortstat = ""
            self.error = error
        }
    }

    /// The working tree is always the newer side. Two commits are ordered by ancestry, then by committer date.
    static func chronological(_ first: String, _ second: String, in directory: URL) async throws -> (String, String) {
        if first == Log.notCommitted.id { return (second, first) }
        if second == Log.notCommitted.id { return (first, second) }
        let onlyInSecond = try await GitRuntime.run(GitRevListCount(directory: directory, revisions: [second, "^" + first]))
        if onlyInSecond == 0 { return (second, first) }
        let onlyInFirst = try await GitRuntime.run(GitRevListCount(directory: directory, revisions: [first, "^" + second]))
        if onlyInFirst == 0 { return (first, second) }
        let times = try await GitRuntime.run(RevisionDiffQuery(directory: directory, arguments: ["show", "-s", "--format=%ct", first, second, "--"]))
            .split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if times.count == 2, times[1] < times[0] { return (second, first) }
        return (first, second)
    }

    /// Base is the old side and target the new side, whichever of them is the working tree.
    static func diffArguments(base: String, target: String) -> [String] {
        var arguments = ["diff"] + GitPatchOptions.stable
        if target == Log.notCommitted.id {
            arguments.append(base)
        } else if base == Log.notCommitted.id {
            arguments += ["-R", target]
        } else {
            arguments += [base, target]
        }
        return arguments + ["--"]
    }
}

/// A read-only Git invocation used by diff views for argument shapes `GitDiff` does not cover.
struct RevisionDiffQuery: GitTextQuery {
    var directory: URL
    var arguments: [String]

    init(directory: URL, arguments: [String]) {
        self.directory = directory
        self.arguments = ["git"] + arguments
    }
}

/// Parses diffs off the main actor and decides which files start expanded.
enum DiffLoading {
    /// Beyond either limit every file starts collapsed, whatever the expansion preference says.
    static let largeDiffFileCount = 80
    static let largeDiffLineCount = 8_000

    static func expandableFileDiffs(raw: String, preference: DiffFileExpansion) async throws -> [ExpandableModel<FileDiff>] {
        let prefersExpanded = preference.isExpanded
        return try await Task.detached(priority: .userInitiated) {
            try expandable(Diff(raw: raw).fileDiffs, rawLineCount: lineCount(raw), prefersExpanded: prefersExpanded)
        }.value
    }

    static func expandable(_ files: [FileDiff], rawLineCount: Int, prefersExpanded: Bool) -> [ExpandableModel<FileDiff>] {
        let isLarge = files.count > largeDiffFileCount || rawLineCount > largeDiffLineCount
        return files.map { file in
            ExpandableModel(isExpanded: prefersExpanded && !isLarge && !startsCollapsed(file.toFilePath.isEmpty ? file.fromFilePath : file.toFilePath),
                            model: file)
        }
    }

    static func lineCount(_ raw: String) -> Int {
        raw.utf8.reduce(into: 0) { count, byte in if byte == UInt8(ascii: "\n") { count += 1 } }
    }

    private static let lockfileNames: Set<String> = [
        "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock",
        "Cargo.lock", "Gemfile.lock", "Podfile.lock", "Package.resolved", "composer.lock", "poetry.lock",
        "Pipfile.lock", "uv.lock", "go.sum", "mix.lock", "pubspec.lock", "packages.lock.json", "flake.lock",
        "gradle.lockfile", "project.pbxproj",
    ]

    /// Lockfiles, minified bundles and generated sources rarely need reading line by line.
    static func startsCollapsed(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if lockfileNames.contains(name) { return true }
        let lowered = name.lowercased()
        if lowered.hasSuffix(".lock") || lowered.hasSuffix(".min.js") || lowered.hasSuffix(".min.css")
            || lowered.hasSuffix(".map") || lowered.hasSuffix(".pb.go") || lowered.hasSuffix(".g.dart")
            || lowered.hasSuffix(".generated.swift") || lowered.hasSuffix(".designer.cs") { return true }
        let components = path.split(separator: "/")
        return components.dropLast().contains { ["node_modules", "vendor", "dist", "generated", "__generated__"].contains($0) }
    }
}
