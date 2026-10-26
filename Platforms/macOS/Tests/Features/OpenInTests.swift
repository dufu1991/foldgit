import AppKit
import XCTest
@testable import FoldGit

private actor OpenInDiscoveryGate {
    var continuations: [URL: CheckedContinuation<[OpenInApplication], Never>] = [:]

    func discover(_ directory: URL) async -> [OpenInApplication] {
        await withCheckedContinuation { continuations[directory] = $0 }
    }

    func complete(_ directory: URL, with applications: [OpenInApplication]) {
        continuations.removeValue(forKey: directory)?.resume(returning: applications)
    }

    func contains(_ directory: URL) -> Bool { continuations[directory] != nil }
}

@MainActor
final class OpenInTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("open-in-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func preferences() throws -> UserDefaults {
        let name = "OpenInTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func application(_ name: String, id: String? = nil, developer: Bool = true, terminal: Bool = false) -> OpenInApplication {
        OpenInApplication(url: URL(fileURLWithPath: "/Applications/\(name).app"), id: id ?? "test.\(name)",
                          name: name, isDeveloperTool: developer, isTerminal: terminal)
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition did not become true")
    }

    func testSettingsCanRegisterAndRemoveCustomApplicationsWithoutOpeningThem() async throws {
        let defaults = try preferences()
        let editor = application("Custom Editor")
        var didOpen = false
        let store = OpenInStore(defaults: defaults, discover: { _, urls, _ in
            urls.isEmpty ? [] : [editor]
        }, openDirectory: { _, _ in didOpen = true })
        store.addCustomApplication(editor)
        store.addCustomApplication(editor)
        XCTAssertTrue(store.isCustomApplication(editor))
        XCTAssertEqual(defaults.stringArray(forKey: PreferenceKey.openInCustomApplications.rawValue), [editor.url.path])
        store.setPinned(true, application: editor)
        await store.reload(for: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(store.pinned, [editor])
        store.removeCustomApplication(editor)
        await store.reload(for: URL(fileURLWithPath: "/tmp"), force: true)
        XCTAssertFalse(store.isCustomApplication(editor))
        XCTAssertTrue(store.applications.isEmpty)
        XCTAssertFalse(didOpen)
    }

    func testDeduplicationUsesBundleIdentityAndExcludesThisApplication() {
        let first = application("Editor")
        let duplicate = OpenInApplication(url: URL(fileURLWithPath: "/tmp/Editor.app"), id: first.id, name: "Editor Old",
                                          isDeveloperTool: true, isTerminal: false)
        let host = application("FoldGit", id: "test.host")
        let result = OpenInApplication.unique([first, duplicate, host], excluding: host.id)
        XCTAssertEqual(result, [first])
    }

    func testMetadataDiscoversUnlistedTerminalWithoutDeveloperCategory() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("New Terminal.app")
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "test.new-terminal.\(UUID().uuidString)",
            "CFBundlePackageType": "APPL", "CFBundleExecutable": "terminal",
            "CFBundleName": "New Terminal", "LSApplicationCategoryType": "public.app-category.utilities",
            "CFBundleDocumentTypes": [["CFBundleTypeRole": "Shell", "LSItemContentTypes": ["public.unix-executable"]]],
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let app = try XCTUnwrap(OpenInApplication.read(at: url))
        XCTAssertTrue(app.isTerminal)
        XCTAssertFalse(app.isDeveloperTool)
        XCTAssertTrue(app.isSuggested)
        XCTAssertEqual(app.name, "New Terminal")
    }

    func testSystemDiscoveryIncludesFolderAndDirectoryHandlersWithoutDuplicates() async throws {
        let directory = try temporaryDirectory()
        let apps = await OpenInApplicationDiscovery().applications(for: directory, customURLs: [])
        let directoryHandlers = NSWorkspace.shared.urlsForApplications(toOpen: .directory)
            .compactMap { OpenInApplication.read(at: $0) }
            .filter { $0.id != Bundle.main.bundleIdentifier }
        XCTAssertTrue(apps.contains(where: \.isFinder))
        XCTAssertTrue(Set(directoryHandlers.map(\.id)).isSubset(of: Set(apps.map(\.id))))
        XCTAssertEqual(apps.count, Set(apps.map(\.id)).count)
    }

    func testPinnedApplicationsPersistAndUtilitiesStayInOtherApplications() async throws {
        let editor = application("Editor")
        let terminal = application("Terminal", developer: false, terminal: true)
        let utility = application("Utility", developer: false)
        let finder = application("Finder", id: "com.apple.finder", developer: false)
        let defaults = try preferences()
        let store = OpenInStore(defaults: defaults, discover: { _, _, _ in [utility, finder, editor, terminal] })
        await store.reload(for: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(store.finder, finder)
        XCTAssertEqual(Set(store.suggested), Set([editor, terminal]))
        XCTAssertEqual(store.others, [utility])
        store.setPinned(true, application: utility)
        store.setPinned(true, application: utility)
        XCTAssertEqual(store.pinned, [utility])
        XCTAssertTrue(store.others.isEmpty)
        let restored = OpenInStore(defaults: defaults)
        XCTAssertEqual(restored.pinnedIDs, [utility.id])
        store.setPinned(false, application: utility)
        XCTAssertEqual(store.others, [utility])
    }

    func testOpenForwardsDirectoryAsURLAndRemembersOnlySuccessfulChoices() async throws {
        let directory = try temporaryDirectory().appendingPathComponent("项目 ' spaces $() &", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = application("Editor")
        let defaults = try preferences()
        var requests: [(URL, URL)] = []
        let store = OpenInStore(defaults: defaults, openDirectory: { requests.append(($0, $1)) })
        try await store.open(app, directory: directory, rememberApplication: true)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.0, directory)
        XCTAssertEqual(requests.first?.1, app.url)
        XCTAssertEqual(store.recentIDs, [app.id])
        XCTAssertEqual(defaults.stringArray(forKey: PreferenceKey.openInCustomApplications.rawValue), [app.url.path])
        XCTAssertTrue(store.applications.contains(app))
        let failingDefaults = try preferences()
        let failing = OpenInStore(defaults: failingDefaults, openDirectory: { _, _ in throw CocoaError(.fileNoSuchFile) })
        do {
            try await failing.open(app, directory: directory, rememberApplication: true)
            XCTFail("Failed launches must be reported")
        } catch {
            XCTAssertTrue(failing.recentIDs.isEmpty)
            XCTAssertNil(failingDefaults.stringArray(forKey: PreferenceKey.openInCustomApplications.rawValue))
            XCTAssertFalse(failing.isOpening)
        }
    }

    func testEditorsAndTerminalsRankBeforeGenericDeveloperTools() async throws {
        let generic = (0..<8).map { application("Developer\($0)") }
        var editor = application("Zed")
        editor.isSourceEditor = true
        let terminal = application("Terminal", developer: false, terminal: true)
        let discovered = generic + [terminal, editor]
        let store = OpenInStore(defaults: try preferences(), discover: { _, _, _ in discovered })
        await store.reload(for: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(Array(store.suggested.prefix(2)), [editor, terminal])
        XCTAssertEqual(store.suggested.count, 6)
        XCTAssertEqual(store.others.count, 4)
    }

    func testDeletedDirectoryIsNotPassedToAnotherApplication() async throws {
        let directory = try temporaryDirectory().appendingPathComponent("deleted")
        var opened = false
        let store = OpenInStore(defaults: try preferences(), openDirectory: { _, _ in opened = true })
        do {
            try await store.open(application("Editor"), directory: directory)
            XCTFail("A missing directory must fail")
        } catch {
            XCTAssertFalse(opened)
            XCTAssertFalse(store.isOpening)
        }
    }

    func testOlderDiscoveryCannotOverwriteResultsForNewRepository() async throws {
        let gate = OpenInDiscoveryGate()
        let first = URL(fileURLWithPath: "/tmp/first")
        let second = URL(fileURLWithPath: "/tmp/second")
        let old = application("Old")
        let new = application("New")
        let store = OpenInStore(defaults: try preferences(), discover: { url, _, _ in await gate.discover(url) })
        let firstTask = Task { await store.reload(for: first) }
        try await eventually { await gate.contains(first) }
        let secondTask = Task { await store.reload(for: second) }
        try await eventually { await gate.contains(second) }
        await gate.complete(second, with: [new])
        await secondTask.value
        await gate.complete(first, with: [old])
        await firstTask.value
        XCTAssertEqual(store.applications, [new])
        XCTAssertFalse(store.isLoading)
    }
}
