import Foundation

/// Group membership is application data. None of these operations move or rename directories.
public enum WorkspaceGroups {
    public static func migratingDirectoryGroups(_ folders: [WorkspaceEntry]) -> [WorkspaceEntry] {
        var seen: Set<URL> = []
        return folders.compactMap { entry in
            if entry.isRepository { return seen.insert(entry.identity).inserted ? entry : nil }
            var group = entry
            if !entry.isLogicalGroup {
                group = .group(name: entry.displayName)
                group.infrequentRepositoryURLs = entry.infrequentRepositoryURLs
            }
            group.children = entry.repositories.filter { seen.insert($0.identity).inserted }
            return group
        }
    }

    public static func uniqueRepositories(_ entries: [WorkspaceEntry]) -> [WorkspaceEntry] {
        var seen: Set<URL> = []
        return entries.flatMap(\.repositories).filter { seen.insert($0.identity).inserted }
    }

    public static func addingRepositories(_ entries: [WorkspaceEntry], to folders: [WorkspaceEntry]) -> [WorkspaceEntry] {
        let present = Set(folders.flatMap(\.repositories).map(\.identity))
        return uniqueRepositories(entries).filter { !present.contains($0.identity) } + folders
    }

    public static func savingGroup(id: URL? = nil, name: String, repositories: [WorkspaceEntry],
                                   in folders: [WorkspaceEntry]) -> [WorkspaceEntry] {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return folders }
        let previous = folders.first { !$0.isRepository && $0.identity == id }
        if id != nil && previous == nil { return folders }
        let members = uniqueRepositories(repositories)
        let selected = Set(members.map(\.identity))
        let inactive = Set(folders.filter { !$0.isRepository }.flatMap(\.infrequentRepositories).map(\.identity))
        var group = previous ?? .group(name: name)
        group.groupName = name
        group.children = members
        group.infrequentRepositoryURLs = members.filter { inactive.contains($0.identity) }.map(\.identity)
        if group.infrequentRepositoryURLs?.isEmpty == true { group.infrequentRepositoryURLs = nil }
        let insertionIndex = id.flatMap { identity in folders.firstIndex { $0.identity == identity } }
            .map { removingRepositories(selected, from: Array(folders.prefix($0))).count } ?? 0
        var remaining = removingRepositories(selected, from: folders).filter { $0.identity != id }
        let released = previous?.repositories.filter { !selected.contains($0.identity) } ?? []
        remaining.insert(contentsOf: [group] + released, at: min(insertionIndex, remaining.count))
        return remaining
    }

    public static func movingRepositories(_ identities: Set<URL>, to groupID: URL?,
                                          in folders: [WorkspaceEntry]) -> [WorkspaceEntry] {
        let members = uniqueRepositories(folders).filter { identities.contains($0.identity) }
        guard !members.isEmpty else { return folders }
        if let groupID {
            guard let group = folders.first(where: { !$0.isRepository && $0.identity == groupID }) else { return folders }
            return savingGroup(id: groupID, name: group.displayName, repositories: group.repositories + members, in: folders)
        }
        return members + removingRepositories(identities, from: folders)
    }

    public static func renamingGroup(_ identity: URL, to name: String, in folders: [WorkspaceEntry]) -> [WorkspaceEntry] {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return folders }
        return folders.map { entry in
            guard !entry.isRepository && entry.identity == identity else { return entry }
            var group = entry
            group.groupName = name
            return group
        }
    }

    public static func dissolvingGroup(_ identity: URL, in folders: [WorkspaceEntry]) -> [WorkspaceEntry] {
        folders.flatMap { entry in
            !entry.isRepository && entry.identity == identity ? entry.repositories : [entry]
        }
    }

    public static func removingRepositories(_ identities: Set<URL>, from folders: [WorkspaceEntry]) -> [WorkspaceEntry] {
        folders.compactMap { entry in
            if entry.isRepository { return identities.contains(entry.identity) ? nil : entry }
            var group = entry
            group.children = entry.repositories.filter { !identities.contains($0.identity) }
            group.infrequentRepositoryURLs = entry.infrequentRepositoryURLs?.filter { !identities.contains(WorkspaceEntry(url: $0).identity) }
            if group.infrequentRepositoryURLs?.isEmpty == true { group.infrequentRepositoryURLs = nil }
            return group
        }
    }
}
