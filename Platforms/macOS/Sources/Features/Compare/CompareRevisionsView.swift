import FoldGitCore
import SwiftUI

struct CompareRevisionsView: View {
    private enum ComparisonSide {
        case base, compare
    }

    var folder: WorkspaceEntry
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var localBranchRefs: [GitRef] = []
    @State private var remoteBranchRefs: [GitRef] = []
    @State private var tagRefs: [GitRef] = []
    @State private var baseRef: GitRef?
    @State private var compareRef: GitRef?
    @State private var currentRef: GitRef?
    @State private var editingSide: ComparisonSide = .base
    @State private var filterText = ""
    @State private var isRemoteExpanded = false
    @State private var isLoading = true
    @State private var isFetching = false
    @State private var diffRefreshID = UUID()
    @State private var error: Error?

    private var filteredLocalBranchRefs: [GitRef] {
        localBranchRefs.filter { filterText.isEmpty || $0.name.localizedCaseInsensitiveContains(filterText) }
    }

    private var filteredRemoteBranchRefs: [GitRef] {
        remoteBranchRefs.filter { filterText.isEmpty || $0.name.localizedCaseInsensitiveContains(filterText) }
    }

    private var filteredTagRefs: [GitRef] {
        tagRefs.filter { filterText.isEmpty || $0.name.localizedCaseInsensitiveContains(filterText) }
    }

    private var editingRef: GitRef? {
        editingSide == .base ? baseRef : compareRef
    }

    private var listSelection: Binding<GitRef.ID?> {
        Binding {
            guard let ref = editingRef, (ref.kind == .tag) == (tab == 1) else { return nil }
            return ref.id
        } set: { id in
            guard let ref = allRefs.first(where: { $0.id == id }) else { return }
            if editingSide == .base {
                baseRef = ref
            } else {
                compareRef = ref
            }
        }
    }

    private var allRefs: [GitRef] {
        localBranchRefs + remoteBranchRefs + tagRefs
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Text("Compare")
                    .font(.title2)
                    .fontWeight(.bold)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .top])
                comparisonControls
                Divider()
                Group {
                    if tab == 0 {
                        List(selection: listSelection) {
                            if !filteredLocalBranchRefs.isEmpty {
                                Section("Local Branches") {
                                    ForEach(filteredLocalBranchRefs) { ref in
                                        BranchRowLabel(name: ref.name, isCurrent: ref.id == currentRef?.id)
                                        .tag(ref.id)
                                    }
                                }
                            }
                            if !filteredRemoteBranchRefs.isEmpty {
                                Section {
                                    DisclosureGroup(isExpanded: $isRemoteExpanded) {
                                        ForEach(filteredRemoteBranchRefs) { ref in
                                            BranchRowLabel(name: ref.name, isRemote: true)
                                                .tag(ref.id)
                                        }
                                    } label: {
                                        Label("Remote Branches", systemImage: "cloud")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .overlay {
                            if filteredLocalBranchRefs.isEmpty && filteredRemoteBranchRefs.isEmpty {
                                Text(filterText.isEmpty ? String(localized: "No Branches") : String(localized: "No Results"))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        List(filteredTagRefs, selection: listSelection) { ref in
                            referenceRow(ref.name, icon: ref.icon)
                                .tag(ref.id)
                        }
                        .overlay {
                            if filteredTagRefs.isEmpty {
                                Text(filterText.isEmpty ? String(localized: "No Tags") : String(localized: "No Results"))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .safeAreaBar(edge: .top, spacing: 0) {
                    HStack {
                        Picker("References", selection: $tab) {
                            Text("Branches").tag(0)
                            Text("Tags").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        if isFetching {
                            ProgressView()
                                .scaleEffect(0.4)
                                .frame(width: 29, height: 17)
                        } else {
                            Button {
                                isFetching = true
                                Task {
                                    defer { isFetching = false }
                                    do {
                                        try await RemoteUpdateService.shared.execute(
                                            GitFetch(directory: folder.url, tags: true)
                                        )
                                        try await loadReferences()
                                        diffRefreshID = UUID()
                                    } catch {
                                        self.error = error
                                    }
                                }
                            } label: {
                                Label("Fetch Branches and Tags", systemImage: "arrow.down")
                                    .labelStyle(.iconOnly)
                            }
                            .help("Fetch Branches and Tags")
                            .disabled(isLoading)
                        }
                    }
                    .padding(10)
                }
            }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease")
                            .foregroundStyle(.secondary)
                        TextField("Filter", text: $filterText)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding()
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            Group {
                if let baseRef, let compareRef {
                    NavigationStack {
                        CompareRevisionContentView(
                            baseRevision: baseRef.revision,
                            compareRevision: compareRef.revision,
                            directoryURL: folder.url
                        )
                        .navigationDestination(for: String.self) { commitHash in
                            CommitDetailView(commitHash: commitHash, folder: folder)
                        }
                    }
                    .id(diffRefreshID)
                } else {
                    CompareNoSelectionView(needsBaseSelection: baseRef == nil)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: 0) {
                    PixelDivider()
                    HStack {
                        Spacer()
                        Button("Close") {
                            dismiss()
                        }
                        .keyboardShortcut(.cancelAction)
                    }
                    .padding()
                }
            }
        }
        .presentationSizing(.fitted)
        .frame(
            minWidth: 650,
            idealWidth: 800,
            maxWidth: .infinity,
            minHeight: 500,
            idealHeight: 700,
            maxHeight: .infinity
        )
        .task {
            defer { isLoading = false }
            do {
                try await loadReferences()
                compareRef = currentRef ?? GitRef(name: "HEAD", kind: .head)
            } catch {
                self.error = error
            }
        }
        .onChange(of: filterText) { _, value in
            isRemoteExpanded = !value.isEmpty || editingRef?.kind == .remoteBranch
        }
        .errorSheet($error)
    }

    private func referenceRow(_ name: String, icon: Image) -> some View {
        HStack(spacing: 6) {
            icon
                .font(.system(size: 13))
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(name)
        }
        .accessibilityElement(children: .combine)
    }

    private var comparisonControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                comparisonSideButton(.base, title: String(localized: "Base"), ref: baseRef)
                Button(action: swapComparison) {
                    Label("Swap Sides", systemImage: "arrow.up.arrow.down")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Swap Sides")
                .disabled(baseRef == nil || compareRef == nil || isLoading)
            }
            comparisonSideButton(.compare, title: String(localized: "Compare"), ref: compareRef)
        }
        .padding(10)
    }

    private func comparisonSideButton(_ side: ComparisonSide, title: String, ref: GitRef?) -> some View {
        Button {
            editingSide = side
            revealEditingRevision()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if let ref {
                        referenceRow(ref.name, icon: ref.icon)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("No Selection")
                            .foregroundStyle(.secondary)
                            .padding(.leading, 22)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(editingSide == side ? Color.accentColor.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityAddTraits(editingSide == side ? [.isSelected] : [])
        .help("Select a branch or tag below to change \(title)")
        .disabled(isLoading)
    }

    private func revealEditingRevision() {
        if let editingRef {
            tab = editingRef.kind == .tag ? 1 : 0
            if editingRef.kind == .remoteBranch {
                isRemoteExpanded = true
            }
        }
    }

    private func swapComparison() {
        guard let baseRef, let compareRef else { return }
        let previousBase = baseRef
        self.baseRef = compareRef
        self.compareRef = previousBase
        revealEditingRevision()
    }

    private func loadReferences() async throws {
        let updatedBranches = try await GitRuntime.run(GitBranch(directory: folder.url)).currentFirst
        let updatedRemoteBranches = try await GitRuntime.run(GitBranch(directory: folder.url, isRemote: true))
        let updatedTags = try await GitRuntime.run(GitTag(directory: folder.url))
        localBranchRefs = updatedBranches.map { branch in
            branch.isDetached
                ? GitRef(name: branch.name, kind: .head)
                : GitRef(name: branch.name, kind: .localBranch)
        }
        currentRef = zip(updatedBranches, localBranchRefs)
            .first(where: { $0.0.isCurrent })?.1
        remoteBranchRefs = updatedRemoteBranches.map {
            GitRef(name: $0.name, kind: .remoteBranch)
        }
        tagRefs = updatedTags.map {
            GitRef(name: $0, kind: .tag)
        }

        if let baseRef {
            self.baseRef = allRefs.first(where: { $0.id == baseRef.id })
        }

        if let compareRef {
            self.compareRef = allRefs.first(where: { $0.id == compareRef.id })
        }
    }
}

private struct CompareNoSelectionView: View {
    let needsBaseSelection: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text("No Selection")
            Text(needsBaseSelection
                 ? String(localized: "Select a branch or tag for Base")
                 : String(localized: "Select a branch or tag for Compare"))
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding()
    }
}

private struct CompareRevisionContentView: View {
    var baseRevision: String
    var compareRevision: String
    var directoryURL: URL

    @State private var tab = 0
    @State private var commits: [Commit] = []
    @State private var commitsLoadFailed = false
    @State private var error: Error?

    var body: some View {
        Group {
            if tab == 0 {
                ScrollView {
                    if commits.isEmpty && !commitsLoadFailed {
                        LazyVStack(alignment: .center) {
                            Label("No Commits", systemImage: "clock")
                                .foregroundStyle(.secondary)
                                .padding()
                                .padding()
                                .padding(.vertical, 40)
                        }
                    } else {
                        DiffCommitListView(commits: commits)
                            .padding()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.textBackgroundColor))
                .scrollEdgeEffectStyle(.hard, for: .vertical)
            } else {
                CommitDiffView(
                    selectionLogID: baseRevision,
                    subSelectionLogID: compareRevision,
                    showsComparisonControls: false
                )
                .environment(\.folder, directoryURL)
            }
        }
        .safeAreaBar(edge: .top, spacing: 0) {
            DiffTabView(tab: $tab)
                .padding()
        }
        .task(id: [baseRevision, compareRevision]) {
            do {
                let updatedCommits = try await GitRuntime.run(
                    GitLog(
                        directory: directoryURL,
                        revisionRange: [baseRevision + "..." + compareRevision]
                    )
                )
                try Task.checkCancellation()
                commits = updatedCommits
                commitsLoadFailed = false
            } catch {
                guard !Task.isCancelled else { return }
                commits = []
                commitsLoadFailed = true
                self.error = error
            }
        }
        .errorSheet($error)
    }
}
