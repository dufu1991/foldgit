import FoldGitCore
import FoldGitTestSupport
import Foundation
import Testing

struct WorkspaceGroupsTests {
    private let api = WorkspaceEntry(url: URL(fileURLWithPath: "/work/api"))
    private let web = WorkspaceEntry(url: URL(fileURLWithPath: "/personal/web"))
    private let docs = WorkspaceEntry(url: URL(fileURLWithPath: "/external/docs"))

    @Test func groupsAreIndependentFromPathsAndPersistStableIdentity() throws {
        let folders = WorkspaceGroups.savingGroup(name: " 跨目录项目 ", repositories: [web, api, web], in: [api, web, docs])
        let group = try #require(folders.first)
        #expect(group.isLogicalGroup)
        #expect(!group.url.isFileURL)
        #expect(group.displayName == "跨目录项目")
        #expect(group.repositories == [web, api])
        #expect(folders == [group, docs])
        let restored = try JSONDecoder().decode([WorkspaceEntry].self, from: JSONEncoder().encode(folders))
        #expect(restored == folders)
        #expect(restored.first?.identity == group.identity)
        let renamed = WorkspaceGroups.renamingGroup(group.identity, to: "另一个名称", in: restored)
        #expect(renamed.first?.identity == group.identity)
        #expect(renamed.first?.repositories == [web, api])
        #expect(renamed.first?.displayName == "另一个名称")
    }

    @Test func movingBetweenGroupsKeepsOneMembershipInactiveFlagAndOrder() throws {
        var source = WorkspaceEntry.group(name: "来源", repositories: [api, web])
        source.setInfrequent(true, repository: api)
        let target = WorkspaceEntry.group(name: "目标", repositories: [docs])
        let folders = WorkspaceGroups.movingRepositories([api.identity], to: target.identity, in: [source, target])
        #expect(folders.map(\.identity) == [source.identity, target.identity])
        #expect(folders[0].repositories == [web])
        #expect(folders[0].infrequentRepositories.isEmpty)
        #expect(folders[1].repositories == [docs, api])
        #expect(folders[1].infrequentRepositories == [api])
        #expect(folders.flatMap(\.repositories).filter { $0.identity == api.identity }.count == 1)
        #expect(WorkspaceGroups.movingRepositories([api.identity], to: target.identity, in: folders) == folders)
    }

    @Test func editingGroupReleasesUncheckedMembersAndDoesNotOverwriteOtherGroups() {
        let group = WorkspaceEntry.group(name: "编辑", repositories: [api, web])
        let other = WorkspaceEntry.group(name: "其他", repositories: [docs])
        let folders = WorkspaceGroups.savingGroup(id: group.identity, name: "编辑后", repositories: [docs, web], in: [group, other])
        #expect(folders[0].identity == group.identity)
        #expect(folders[0].repositories == [docs, web])
        #expect(folders[1] == api)
        #expect(folders[2].identity == other.identity)
        #expect(folders[2].repositories.isEmpty)
        #expect(Set(folders.flatMap(\.repositories).map(\.identity)) == [api.identity, web.identity, docs.identity])
    }

    @Test func editingRetainsGroupPositionWhenEarlierUngroupedEntriesBecomeMembers() {
        let first = WorkspaceEntry.group(name: "前一组", repositories: [docs])
        let target = WorkspaceEntry.group(name: "目标", repositories: [web])
        let folders = WorkspaceGroups.savingGroup(id: target.identity, name: target.displayName,
                                                 repositories: [web, api], in: [api, first, target])
        #expect(folders.map(\.identity) == [first.identity, target.identity])
    }

    @Test func ungroupingAndDissolvingKeepRepositoriesAndTheirOriginalURLs() {
        let group = WorkspaceEntry.group(name: "项目", repositories: [api, web])
        let moved = WorkspaceGroups.movingRepositories([web.identity], to: nil, in: [group, docs])
        #expect(moved[0] == web)
        #expect(moved[1].repositories == [api])
        #expect(WorkspaceGroups.dissolvingGroup(group.identity, in: [group, docs]) == [api, web, docs])
        let removed = WorkspaceGroups.removingRepositories([api.identity], from: [group, docs])
        #expect(removed[0].repositories == [web])
        #expect(removed[1] == docs)
    }

    @Test func emptyGroupsAndDuplicateNamesHaveIndependentIdentities() {
        let first = WorkspaceEntry.group(name: "项目")
        let second = WorkspaceEntry.group(name: "项目")
        #expect(first.repositories.isEmpty)
        #expect(first.identity != second.identity)
        let folders = WorkspaceGroups.savingGroup(name: "项目", repositories: [], in: [first])
        #expect(folders.count == 2)
        #expect(folders.allSatisfy { !$0.isRepository })
        #expect(WorkspaceGroups.renamingGroup(first.identity, to: " \n", in: [first]) == [first])
    }

    @Test func directoryMigrationRetainsNamesOrderInactiveChoicesAndSelectionURLs() throws {
        var old = WorkspaceEntry(url: URL(fileURLWithPath: "/work"), children: [web, api])
        old.setInfrequent(true, repository: web)
        let original = [old, docs]
        let legacy = try JSONDecoder().decode([WorkspaceEntry].self, from: JSONEncoder().encode(original))
        let migrated = WorkspaceGroups.migratingDirectoryGroups(legacy)
        #expect(migrated[0].isLogicalGroup)
        #expect(migrated[0].displayName == "work")
        #expect(migrated[0].repositories == [web, api])
        #expect(migrated[0].infrequentRepositories == [web])
        #expect(migrated[1] == docs)
        #expect(WorkspaceGroups.migratingDirectoryGroups(migrated) == migrated)
        let rescanned = WorkspaceEntry(url: old.url, children: [docs])
        #expect(migrated[0].mergingDiscovery(rescanned) == migrated[0])
    }

    @Test func addingRepositoryDoesNotInferGroupFromItsFilesystemParent() {
        let sibling = WorkspaceEntry(url: api.url.deletingLastPathComponent().appendingPathComponent("new"))
        let group = WorkspaceEntry.group(name: "自定义", repositories: [api])
        #expect(WorkspaceGroups.addingRepositories([sibling], to: [group]) == [sibling, group])
        #expect(WorkspaceGroups.addingRepositories([api], to: [group]) == [group])
    }

    @Test func groupingRepositoriesFromDifferentDirectoriesDoesNotChangeFilesOrGitState() async throws {
        let first = try await TestRepository.create()
        let second = try await TestRepository.create()
        defer { first.remove(); second.remove() }
        let entries = [WorkspaceEntry(url: first.url), WorkspaceEntry(url: second.url)]
        let heads = try await [first.git(["rev-parse", "HEAD"]), second.git(["rev-parse", "HEAD"])]
        let grouped = WorkspaceGroups.savingGroup(name: "跨目录", repositories: entries, in: entries)
        let renamed = WorkspaceGroups.renamingGroup(grouped[0].identity, to: "改名", in: grouped)
        #expect(WorkspaceGroups.dissolvingGroup(renamed[0].identity, in: renamed) == entries)
        #expect(FileManager.default.fileExists(atPath: first.url.appendingPathComponent("example.swift").path))
        #expect(FileManager.default.fileExists(atPath: second.url.appendingPathComponent("example.swift").path))
        #expect(try await first.git(["rev-parse", "HEAD"]) == heads[0])
        #expect(try await second.git(["rev-parse", "HEAD"]) == heads[1])
        #expect(try await first.git(["status", "--porcelain"]).isEmpty)
        #expect(try await second.git(["status", "--porcelain"]).isEmpty)
    }
}
