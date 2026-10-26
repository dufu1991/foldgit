import AppKit
import UniformTypeIdentifiers

struct OpenInApplication: Identifiable, Hashable, Sendable {
    let url: URL
    let id: String
    let name: String
    let isDeveloperTool: Bool
    let isTerminal: Bool
    var isSourceEditor = false

    var isFinder: Bool { id == "com.apple.finder" }
    var isSuggested: Bool { isSourceEditor || isDeveloperTool || isTerminal }
    var suggestionRank: Int { isTerminal ? 1 : isSourceEditor ? 0 : 2 }

    static func read(at url: URL) -> OpenInApplication? {
        guard url.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: url.path),
              let bundle = Bundle(url: url), let info = bundle.infoDictionary,
              info["CFBundleExecutable"] is String,
              info["LSBackgroundOnly"] as? Bool != true else { return nil }
        let documents = info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        let isTerminal = documents.contains { document in
            document["CFBundleTypeRole"] as? String == "Shell" ||
            !(Set(document["CFBundleTypeExtensions"] as? [String] ?? []).intersection(["command", "tool"]).isEmpty)
        }
        let isSourceEditor = documents.contains { document in
            let identifiers = document["LSItemContentTypes"] as? [String] ?? []
            let extensions = document["CFBundleTypeExtensions"] as? [String] ?? []
            let types = identifiers.compactMap { UTType($0) } + extensions.compactMap { UTType(filenameExtension: $0) }
            return types.contains { $0.conforms(to: .sourceCode) }
        }
        let localized = bundle.localizedInfoDictionary
        let name = localized?["CFBundleDisplayName"] as? String ?? localized?["CFBundleName"] as? String
            ?? info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent
        return OpenInApplication(url: url.standardizedFileURL.resolvingSymlinksInPath(),
                                 id: bundle.bundleIdentifier ?? url.standardizedFileURL.resolvingSymlinksInPath().path,
                                 name: name,
                                 isDeveloperTool: info["LSApplicationCategoryType"] as? String == "public.app-category.developer-tools",
                                 isTerminal: isTerminal, isSourceEditor: isSourceEditor)
    }

    static func unique(_ applications: [OpenInApplication], excluding identifier: String?) -> [OpenInApplication] {
        var identifiers: Set<String> = []
        return applications.filter { $0.id != identifier && identifiers.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

actor OpenInApplicationDiscovery {
    static let shared = OpenInApplicationDiscovery()
    private var cachedDirectory: URL?
    private var cachedApplications: [OpenInApplication] = []
    private var lastScan = Date.distantPast

    func applications(for directory: URL, customURLs: [URL], force: Bool = false) async -> [OpenInApplication] {
        if force || directory != cachedDirectory || Date().timeIntervalSince(lastScan) >= 60 {
            let workspace = NSWorkspace.shared
            // Some apps register public.directory rather than public.folder. Query both
            // so terminals are discovered without a hard-coded application registry.
            let urls = workspace.urlsForApplications(toOpen: directory)
                + workspace.urlsForApplications(toOpen: UTType.folder)
                + workspace.urlsForApplications(toOpen: UTType.directory)
            var visited: Set<URL> = []
            let candidates = urls.filter { visited.insert($0.standardizedFileURL.resolvingSymlinksInPath()).inserted }
            let applications = candidates.compactMap { OpenInApplication.read(at: $0) }
            // Launch Services chooses the installed copy to use when multiple versions exist.
            let preferred = Set(applications.compactMap { application in
                workspace.urlForApplication(withBundleIdentifier: application.id)?.standardizedFileURL.resolvingSymlinksInPath()
            })
            cachedApplications = OpenInApplication.unique(
                applications.sorted { preferred.contains($0.url) && !preferred.contains($1.url) },
                excluding: Bundle.main.bundleIdentifier
            )
            cachedDirectory = directory
            lastScan = Date()
        }
        return OpenInApplication.unique(cachedApplications + customURLs.compactMap { OpenInApplication.read(at: $0) },
                                        excluding: Bundle.main.bundleIdentifier)
    }
}
