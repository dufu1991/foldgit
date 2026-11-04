import AppKit
import Foundation
import Combine
import Sparkle

/// Owns Sparkle's authenticated download, installation and relaunch lifecycle.
@MainActor
final class UpdateChecker: NSObject, ObservableObject {
    static let shared = UpdateChecker()
    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController
    private var hasStarted = false

    private override init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        super.init()
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    static func checksAtLaunch(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: PreferenceKey.checkForUpdatesAtLaunch.rawValue) as? Bool ?? true
    }

    func checkAtLaunch() {
        #if !DEBUG
        guard ProcessInfo.processInfo.environment["FOLDGIT_TESTING"] != "1", !hasStarted else { return }
        hasStarted = true
        controller.startUpdater()
        controller.updater.automaticallyChecksForUpdates = Self.checksAtLaunch()
        if controller.updater.automaticallyChecksForUpdates {
            controller.updater.checkForUpdatesInBackground()
        }
        #endif
    }

    func setAutomaticChecks(_ enabled: Bool) {
        #if !DEBUG
        guard hasStarted else { return }
        controller.updater.automaticallyChecksForUpdates = enabled
        #endif
    }

    func checkNow() {
        #if !DEBUG
        guard hasStarted, canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
        #endif
    }
}
