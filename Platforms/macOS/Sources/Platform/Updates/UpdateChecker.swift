import AppKit
import Foundation

/// A release version such as `0.1.1`, compared component by component so `0.10.0` follows `0.9.0`.
struct AppVersion: Comparable, CustomStringConvertible {
    let components: [Int]

    /// Accepts release tags with a leading `v` and ignores suffixes such as `-beta`.
    init?(_ text: String) {
        var text = Substring(text.trimmingCharacters(in: .whitespaces))
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        let core = text.prefix { $0.isNumber || $0 == "." }
        let components = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !components.isEmpty, !components.contains(nil) else { return nil }
        self.components = components.compactMap { $0 }
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// Asks GitHub for the latest published release and tells the user when it is newer than this build.
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()
    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/dufu1991/foldgit/releases/latest")!
    private static let releasesPage = URL(string: "https://github.com/dufu1991/foldgit/releases/latest")!

    private var isChecking = false

    static func checksAtLaunch(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: PreferenceKey.checkForUpdatesAtLaunch.rawValue) as? Bool ?? true
    }

    private var currentVersion: AppVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
    }

    /// Launch checks stay silent unless a newer version exists.
    func checkAtLaunch() {
        guard ProcessInfo.processInfo.environment["FOLDGIT_TESTING"] != "1", Self.checksAtLaunch() else { return }
        Task { await check(userInitiated: false) }
    }

    func checkNow() {
        Task { await check(userInitiated: true) }
    }

    private func check(userInitiated: Bool) async {
        guard !isChecking, let currentVersion else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let latest = try await fetchLatestVersion()
            if currentVersion < latest {
                presentUpdate(latest, current: currentVersion)
            } else if userInitiated {
                present(title: String(localized: "FoldGit Is Up to Date"),
                        message: String(localized: "You are using the latest version, \(currentVersion.description)."))
            }
        } catch {
            if userInitiated {
                present(title: String(localized: "Unable to Check for Updates"), message: error.localizedDescription)
            }
        }
    }

    private func fetchLatestVersion() async throws -> AppVersion {
        struct Release: Decodable { let tag_name: String }
        var request = URLRequest(url: Self.latestReleaseAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("FoldGit", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let version = AppVersion(try JSONDecoder().decode(Release.self, from: data).tag_name) else {
            throw URLError(.badServerResponse)
        }
        return version
    }

    private func presentUpdate(_ latest: AppVersion, current: AppVersion) {
        let alert = NSAlert()
        alert.messageText = String(localized: "A New Version of FoldGit Is Available")
        alert.informativeText = String(localized: "FoldGit \(latest.description) is available. You are using \(current.description).")
        alert.addButton(withTitle: String(localized: "Download"))
        alert.addButton(withTitle: String(localized: "Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            if !NSWorkspace.shared.open(Self.releasesPage) {
                present(title: String(localized: "Open Release Page"),
                        message: String(localized: "The release page could not be opened."))
            }
        }
    }

    private func present(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}
