import FoldGitCore
import Foundation
import Testing
@testable import FoldGit

struct SidebarOrganizationTests {
    private let api = WorkspaceEntry(url: URL(fileURLWithPath: "/projects/work/api"))
    private let web = WorkspaceEntry(url: URL(fileURLWithPath: "/projects/work/web"))
    private let other = WorkspaceEntry(url: URL(fileURLWithPath: "/projects/personal/site"))

    @Test func searchMatchesGroupOriginalNameAndAliasWithoutChangingSavedEntries() {
        var group = WorkspaceEntry(url: api.url.deletingLastPathComponent(), children: [web, api])
        group.setInfrequent(true, repository: web)
        var names = RepositoryDisplayNames()
        names.setName("客户网站", for: web)
        let original = [group, other]
        var projection = SidebarOrganization(folders: original, names: names, query: "WORK")
        #expect(projection.entries == [group])
        projection.query = "客户"
        #expect(projection.entries.first?.children == [web])
        #expect(projection.entries.first?.infrequentRepositories == [web])
        projection.query = "WEB"
        #expect(projection.entries.first?.children == [web])
        projection.query = "missing"
        #expect(projection.entries.isEmpty)
        projection.query = ""
        #expect(projection.entries == original)
        #expect(projection.canMove)
    }

    @Test func namesUseNaturalOrderAndManualOrderSurvivesAutomaticSorting() {
        let ten = WorkspaceEntry(url: URL(fileURLWithPath: "/project10"))
        let two = WorkspaceEntry(url: URL(fileURLWithPath: "/project2"))
        var names = RepositoryDisplayNames()
        names.setName("project1", for: other)
        let original = [ten, two, other]
        var projection = SidebarOrganization(folders: original, names: names)
        #expect(projection.sort == .manual)
        #expect(projection.entries == original)
        projection.sort = .name
        #expect(projection.entries == [other, two, ten])
        #expect(!projection.canMove)
        projection.ascending = false
        #expect(projection.entries == [ten, two, other])
        projection.sort = .manual
        #expect(projection.entries == original)
        projection.query = "project"
        #expect(!projection.canMove)
    }

    @Test func dateSortsUseLatestChildDateStableTiesAndUnknownDatesLast() {
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)
        let group = WorkspaceEntry(url: api.url.deletingLastPathComponent(), children: [api, web])
        let unknown = WorkspaceEntry(url: URL(fileURLWithPath: "/unknown"))
        let values = [api.identity.path: old, web.identity.path: new, other.identity.path: old]
        var projection = SidebarOrganization(folders: [other, unknown, group], names: RepositoryDisplayNames(),
                                             sort: .recentlyOpened, ascending: false,
                                             dates: SidebarDates(added: values, opened: values), modified: values)
        for mode in [SidebarSort.recentlyOpened, .recentlyAdded, .recentlyModified] {
            projection.sort = mode
            projection.ascending = false
            #expect(projection.entries == [group, other, unknown])
            projection.ascending = true
            #expect(projection.entries == [other, group, unknown])
        }
    }

    @Test func manualChildReorderPreservesInfrequentSlotsAndSurvivesDiscovery() {
        let newer = WorkspaceEntry(url: api.url.deletingLastPathComponent().appendingPathComponent("new"))
        let reordered = SidebarOrganization.moving([api, web], in: [api, other, web], from: IndexSet(integer: 0), to: 2)
        #expect(reordered == [web, other, api])
        let group = WorkspaceEntry(url: api.url.deletingLastPathComponent(), children: [web, api])
        let discovered = WorkspaceEntry(url: group.url, children: [api, newer, web])
        #expect(group.mergingDiscovery(discovered).children == [web, api, newer])
    }

    @Test func addedRepositoryKeepsItsExplicitGroupMembershipAndDatesPersist() throws {
        var group = WorkspaceEntry.group(name: "工作项目", repositories: [api])
        group.setInfrequent(true, repository: api)
        let added = SidebarOrganization.adding(web, to: [group, other])
        #expect(added == [web, group, other])
        #expect(SidebarOrganization.adding(web, to: added) == added)
        #expect(SidebarOrganization.adding(api, to: added) == added)
        var dates = SidebarDates()
        let first = Date(timeIntervalSince1970: 100)
        dates.register([group], now: first)
        dates.register(added, now: Date(timeIntervalSince1970: 200))
        #expect(dates.added[api.identity.path] == first)
        #expect(dates.added[web.identity.path] == Date(timeIntervalSince1970: 200))
        #expect(SidebarDates.decode(try JSONEncoder().encode(dates)) == dates)
    }
}
