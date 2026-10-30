import FoldGitCore
import SwiftUI

struct RepositoryGroupDraft: Identifiable {
    let id = UUID()
    var groupID: URL?
    var name: String
    var selected: [WorkspaceEntry]
    var incoming: [WorkspaceEntry] = []
}

struct RepositoryGroupEditor: View {
    let draft: RepositoryGroupDraft
    let folders: [WorkspaceEntry]
    let names: RepositoryDisplayNames
    let onSave: (String, [WorkspaceEntry]) -> Void
    @State private var name: String
    @State private var candidates: [WorkspaceEntry]
    @State private var selected: Set<URL>
    @State private var filter = ""
    @State private var isAdding = false
    @State private var errorMessage: String?
    @FocusState private var nameIsFocused: Bool
    @Environment(\.dismiss) private var dismiss
    private let discovery = MacRepositoryDiscovery.make()

    init(draft: RepositoryGroupDraft, folders: [WorkspaceEntry], names: RepositoryDisplayNames,
         onSave: @escaping (String, [WorkspaceEntry]) -> Void) {
        self.draft = draft
        self.folders = folders
        self.names = names
        self.onSave = onSave
        _name = State(initialValue: draft.name)
        _candidates = State(initialValue: WorkspaceGroups.uniqueRepositories(draft.selected + folders.flatMap(\.repositories) + draft.incoming))
        _selected = State(initialValue: Set(draft.selected.map(\.identity)))
    }

    private var filtered: [WorkspaceEntry] {
        let filter = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidates.filter {
            filter.isEmpty || names.displayName(for: $0).localizedStandardContains(filter)
                || $0.url.path.localizedStandardContains(filter)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.groupID == nil ? String(localized: "New Group") : String(localized: "Manage Group"))
                .font(.headline)
            Text("Groups organize repositories without moving their folders. A repository belongs to one group at a time.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Group Name", text: $name)
                .textFieldStyle(.roundedBorder).focused($nameIsFocused)
                .accessibilityIdentifier("repositoryGroupName")
            TextField("Filter Repositories", text: $filter)
                .textFieldStyle(.roundedBorder)
            List {
                ForEach(filtered, id: \.identity) { repository in
                    Toggle(isOn: Binding(
                        get: { selected.contains(repository.identity) },
                        set: { enabled in
                            if enabled { selected.insert(repository.identity) }
                            else { selected.remove(repository.identity) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(names.displayName(for: repository))
                                Spacer()
                                if let group = folders.first(where: { !$0.isRepository && $0.repositories.contains { $0.identity == repository.identity } }) {
                                    Text(group.displayName).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(repository.url.path).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.vertical, 3)
                }
            }
            .listStyle(.inset)
            .frame(height: 260)
            .overlay {
                if candidates.isEmpty {
                    Text("Add repositories from Finder to include them in this group.").foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding()
                }
            }
            HStack {
                Button("Add Repositories from Finder", systemImage: "folder.badge.plus", action: chooseRepositories)
                    .disabled(isAdding)
                if isAdding { ProgressView().controlSize(.small) }
                Spacer()
                LabeledContent("Selected Repositories") { Text(selected.count, format: .number) }
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout).lineLimit(3)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(name, candidates.filter { selected.contains($0.identity) })
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAdding)
            }
        }
        .padding(24).frame(width: 600)
        .task { nameIsFocused = true }
    }

    private func chooseRepositories() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.title = String(localized: "Add Repositories from Finder")
        panel.message = String(localized: "Choose repositories from any location, or a directory containing repositories.")
        panel.begin { response in
            guard response == .OK else { return }
            Task { @MainActor in
                isAdding = true
                errorMessage = nil
                defer { isAdding = false }
                do {
                    var incoming: [WorkspaceEntry] = []
                    for url in panel.urls { incoming += try await discovery.inspect(url).repositories }
                    candidates = WorkspaceGroups.uniqueRepositories(candidates + incoming)
                    selected.formUnion(incoming.map(\.identity))
                    filter = ""
                } catch {
                    errorMessage = OperationFailure("Add Repositories from Finder", error).localizedDescription
                }
            }
        }
    }
}

struct RepositoryGroupNameSheet: View {
    @State var name: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Group").font(.headline)
            TextField("Group Name", text: $name).textFieldStyle(.roundedBorder).focused($nameIsFocused)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(name) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 400)
        .task { nameIsFocused = true }
    }
}
