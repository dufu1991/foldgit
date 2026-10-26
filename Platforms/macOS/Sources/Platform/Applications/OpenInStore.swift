import AppKit
import Observation

@MainActor
@Observable final class OpenInStore {
    private(set) var applications: [OpenInApplication] = []
    private(set) var pinnedIDs: [String] = []
    private(set) var recentIDs: [String] = []
    private(set) var isLoading = false
    private(set) var isOpening = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let discover: @Sendable (URL, [URL], Bool) async -> [OpenInApplication]
    @ObservationIgnored private let openDirectory: @MainActor (URL, URL) async throws -> Void
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var icons: [URL: NSImage] = [:]

    init(defaults: UserDefaults = .standard,
         discover: @escaping @Sendable (URL, [URL], Bool) async -> [OpenInApplication] = {
             await OpenInApplicationDiscovery.shared.applications(for: $0, customURLs: $1, force: $2)
         },
         openDirectory: @escaping @MainActor (URL, URL) async throws -> Void = { directory, application in
             _ = try await NSWorkspace.shared.open([directory], withApplicationAt: application,
                                                  configuration: NSWorkspace.OpenConfiguration())
         }) {
        self.defaults = defaults
        self.discover = discover
        self.openDirectory = openDirectory
        reloadPreferences()
    }

    var finder: OpenInApplication? { applications.first(where: \.isFinder) }
    var pinned: [OpenInApplication] { pinnedIDs.compactMap { id in applications.first { $0.id == id && !$0.isFinder } } }
    var suggested: [OpenInApplication] {
        let recent = recentIDs.compactMap { id in applications.first { $0.id == id } }
        var included = Set(pinnedIDs)
        let recommended = applications.filter(\.isSuggested).sorted {
            if $0.suggestionRank != $1.suggestionRank { return $0.suggestionRank < $1.suggestionRank }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return Array((recent + recommended).filter {
            !$0.isFinder && included.insert($0.id).inserted
        }.prefix(6))
    }
    var others: [OpenInApplication] {
        let visible = Set((pinned + suggested).map(\.id))
        return applications.filter { !$0.isFinder && !visible.contains($0.id) }
    }

    func reloadPreferences() {
        pinnedIDs = defaults.stringArray(forKey: PreferenceKey.openInPinnedApplications.rawValue) ?? []
        recentIDs = defaults.stringArray(forKey: PreferenceKey.openInRecentApplications.rawValue) ?? []
    }

    func reload(for directory: URL, force: Bool = false) async {
        generation += 1
        let current = generation
        isLoading = true
        reloadPreferences()
        let customURLs = (defaults.stringArray(forKey: PreferenceKey.openInCustomApplications.rawValue) ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let discovered = await discover(directory, customURLs, force)
        guard current == generation else { return }
        isLoading = false
        guard !Task.isCancelled else { return }
        applications = OpenInApplication.unique(discovered, excluding: Bundle.main.bundleIdentifier)
        icons = icons.filter { url, _ in applications.contains { $0.url == url } }
    }

    func icon(for application: OpenInApplication) -> NSImage {
        if let image = icons[application.url] { return image }
        let image = NSWorkspace.shared.icon(forFile: application.url.path)
        image.size = NSSize(width: 16, height: 16)
        icons[application.url] = image
        return image
    }

    func setPinned(_ pinned: Bool, application: OpenInApplication) {
        reloadPreferences()
        pinnedIDs.removeAll { $0 == application.id }
        if pinned && !application.isFinder { pinnedIDs.append(application.id) }
        defaults.set(pinnedIDs, forKey: PreferenceKey.openInPinnedApplications.rawValue)
    }

    func isCustomApplication(_ application: OpenInApplication) -> Bool {
        (defaults.stringArray(forKey: PreferenceKey.openInCustomApplications.rawValue) ?? []).contains(application.url.path)
    }

    func addCustomApplication(_ application: OpenInApplication) {
        guard application.id != Bundle.main.bundleIdentifier else { return }
        var paths = defaults.stringArray(forKey: PreferenceKey.openInCustomApplications.rawValue) ?? []
        paths.removeAll { $0 == application.url.path }
        paths.append(application.url.path)
        defaults.set(paths, forKey: PreferenceKey.openInCustomApplications.rawValue)
        applications = OpenInApplication.unique(applications + [application], excluding: Bundle.main.bundleIdentifier)
    }

    func removeCustomApplication(_ application: OpenInApplication) {
        var paths = defaults.stringArray(forKey: PreferenceKey.openInCustomApplications.rawValue) ?? []
        paths.removeAll { $0 == application.url.path }
        defaults.set(paths, forKey: PreferenceKey.openInCustomApplications.rawValue)
    }

    func open(_ application: OpenInApplication, directory: URL, rememberApplication: Bool = false) async throws {
        guard !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw CocoaError(.fileReadNoSuchFile) }
        try await openDirectory(directory, application.url)
        reloadPreferences()
        recentIDs.removeAll { $0 == application.id }
        recentIDs.insert(application.id, at: 0)
        recentIDs = Array(recentIDs.prefix(6))
        defaults.set(recentIDs, forKey: PreferenceKey.openInRecentApplications.rawValue)
        if rememberApplication {
            addCustomApplication(application)
        }
    }
}
