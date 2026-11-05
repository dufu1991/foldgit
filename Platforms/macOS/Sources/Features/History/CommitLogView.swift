import FoldGitCore
import SwiftUI

struct CommitLogView: View {
    @Environment(\.folder) private var folder
    var logStore: HistoryStore
    @Binding var selectionLogID: String?
    @Binding var subSelectionLogID: String?
    @Binding var showing: RepositoryPresentation
    @Binding var isRefresh: Bool
    @Binding var error: Error?
    private var selectionLogIDs: Set<String> { logStore.selectedHashes }

    var body: some View {
        ScrollViewReader { proxy in
            List(logStore.logs(), selection: Binding(get: { logStore.selectedHashes }, set: { if logStore.selectedHashes != $0 { logStore.selectedHashes = $0 } })) { log in
                logsRow(log)
                    .id(log.id)
                    .task {
                        await logStore.logViewTask(log)
                    }
            }
            .onChange(of: selectionLogIDs) { _, newValue in
                let ordered = logStore.logs().filter { newValue.contains($0.id) }
                selectionLogID = ordered.first?.id
                subSelectionLogID = ordered.count > 1 ? ordered.last?.id : nil
                if newValue.count == 1 { logStore.selectionAnchor = newValue.first }
            }
            .onChange(of: selectionLogID ?? "") {
                syncSelection()
            }
            .onChange(of: subSelectionLogID ?? "") {
                syncSelection()
            }
            .task {
                syncSelection()
            }
            .task(id: logStore.scrollRequest?.id) {
                guard let request = logStore.scrollRequest else { return }
                await Task.yield()
                proxy.scrollTo(request.target, anchor: .center)
            }
        }
    }

    fileprivate func syncSelection() {
        if subSelectionLogID != nil, logStore.selectedHashes.count > 2, logStore.selectedHashes.contains(selectionLogID ?? "") { return }
        var newValues = Set<String>()
        if let selectionLogID {
            newValues.insert(selectionLogID)
        }
        if let subSelectionLogID {
            newValues.insert(subSelectionLogID)
        }
        // Defer the write so it does not modify state during the current view update.
        Task { if logStore.selectedHashes != newValues { logStore.selectedHashes = newValues } }
    }

    fileprivate func logsRow(_ log: Log) -> some View {
        return VStack {
            switch log {
            case .notCommitted:
                UncommittedChangesLabel(isSelected: selectionLogIDs.contains(log.id))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        if !selectionLogIDs.contains(log.id) {
                            UncommittedChangesBackground()
                        }
                    }
                    .padding(.vertical, 4)
            case .committed(let commit):
                if let folder {
                    CommitRowView(commit: commit, outsideCurrentBranch: logStore.isOutsideCurrentBranch(commit.id),
                                  isSelected: selectionLogIDs.contains(commit.id), incoming: logStore.isIncoming(commit.id),
                                  outgoing: logStore.isOutgoing(commit.id))
                        .commitContextMenu(
                            folder: folder,
                            commit: commit,
                            logStore: logStore,
                            isRefresh: $isRefresh,
                            showing: $showing,
                            bindingError: $error
                        )
                }
            }
        }
    }
}

struct UncommittedChangesLabel: View {
    var showsIcon = true
    var isSelected = false

    var body: some View {
        HStack(spacing: 10) {
            if showsIcon {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(HierarchicalShapeStyle.primary) : AnyShapeStyle(Color.orange))
                    .frame(width: 24, height: 24)
                    .background(Color.orange.opacity(isSelected ? 0 : 0.12),
                                in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Uncommitted Changes")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text("Working Tree")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct UncommittedChangesBackground: View {
    var isSelected = false

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill((isSelected ? Color.accentColor : .orange).opacity(isSelected ? 0.14 : 0.07))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder((isSelected ? Color.accentColor : .orange).opacity(isSelected ? 0.5 : 0.3))
            }
    }
}
