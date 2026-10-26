import Foundation

public struct WorkspaceEntry: Hashable, Codable, Sendable {
    public init(url: URL, children: [WorkspaceEntry]? = nil, infrequentRepositoryURLs: [URL]? = nil) {
        self.url = url
        self.children = children
        self.infrequentRepositoryURLs = infrequentRepositoryURLs
    }

    public var url: URL
    /// A missing children field also preserves repositories saved by earlier versions.
    public var children: [WorkspaceEntry]? = nil
    /// Sidebar-only preferences belong to the group, leaving repository identity unchanged.
    public var infrequentRepositoryURLs: [URL]? = nil
    /// Logical groups have a stable non-file URL and a name independent of any directory.
    public var groupName: String? = nil

    public var isRepository: Bool { children == nil }
    public var isLogicalGroup: Bool { !isRepository && url.scheme == "foldgit-group" }
    public var repositories: [WorkspaceEntry] { children?.flatMap(\.repositories) ?? [self] }
    public var identity: URL { url.isFileURL ? RepositoryLocation.canonical(url) : url }
    public var frequentRepositories: [WorkspaceEntry] {
        let infrequent = Set((infrequentRepositoryURLs ?? []).map { WorkspaceEntry(url: $0).identity })
        return (children ?? []).filter { !infrequent.contains($0.identity) }
    }
    public var infrequentRepositories: [WorkspaceEntry] {
        let infrequent = Set((infrequentRepositoryURLs ?? []).map { WorkspaceEntry(url: $0).identity })
        return (children ?? []).filter { infrequent.contains($0.identity) }
    }

    public mutating func setInfrequent(_ infrequent: Bool, repository: WorkspaceEntry) {
        guard children?.contains(where: { $0.identity == repository.identity }) == true else { return }
        var urls = (infrequentRepositoryURLs ?? []).filter { WorkspaceEntry(url: $0).identity != repository.identity }
        if infrequent { urls.append(repository.identity) }
        infrequentRepositoryURLs = urls.isEmpty ? nil : urls
    }

    public func mergingDiscovery(_ discovered: WorkspaceEntry) -> WorkspaceEntry {
        guard !isLogicalGroup else { return self }
        guard !isRepository, !discovered.isRepository, identity == discovered.identity else { return discovered }
        var refreshed = discovered
        let previousOrder = Dictionary(uniqueKeysWithValues: (children ?? []).enumerated().map { ($0.element.identity, $0.offset) })
        refreshed.children = discovered.children?.enumerated().sorted {
            let lhs = previousOrder[$0.element.identity]
            let rhs = previousOrder[$1.element.identity]
            if let lhs, let rhs { return lhs < rhs }
            if lhs != nil || rhs != nil { return lhs != nil }
            return $0.offset < $1.offset
        }.map(\.element)
        refreshed.infrequentRepositoryURLs = infrequentRepositoryURLs
        return refreshed
    }

    public var displayName: String {
        groupName ?? url.lastPathComponent
    }

    public static func group(name: String, repositories: [WorkspaceEntry] = [], id: UUID = UUID()) -> WorkspaceEntry {
        var group = WorkspaceEntry(url: URL(string: "foldgit-group://\(id.uuidString)")!, children: repositories)
        group.groupName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return group
    }
}
