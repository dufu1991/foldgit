import AppKit
import Foundation
import ServiceManagement
import SwiftUI

// Persist stable identifiers so preference values do not depend on the interface language.
enum AppAppearance: String, CaseIterable, Identifiable {
    case automatic, light, dark
    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .automatic: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum InterfaceLanguage: String, CaseIterable, Identifiable, Sendable {
    case automatic, simplifiedChinese = "zh-Hans", traditionalChinese = "zh-Hant"
    case english = "en", japanese = "ja", korean = "ko", french = "fr", spanish = "es", russian = "ru"
    var id: Self { self }
    var title: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .english: "English"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .french: "Français"
        case .spanish: "Español"
        case .russian: "Русский"
        }
    }

    func apply(to defaults: UserDefaults = .standard) {
        if self == .automatic {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

struct InterfaceLanguageSession: Sendable {
    static let shared = Self()
    let launchedLanguage: InterfaceLanguage

    init(defaults: UserDefaults = .standard) {
        launchedLanguage = defaults.string(forKey: PreferenceKey.interfaceLanguage.rawValue)
            .flatMap(InterfaceLanguage.init(rawValue:)) ?? .automatic
    }

    func requiresRestart(for language: InterfaceLanguage) -> Bool {
        language != launchedLanguage
    }
}

enum DiffFileExpansion: String, CaseIterable, Identifiable {
    case expanded, collapsed
    var id: Self { self }
    var isExpanded: Bool { self == .expanded }

    var title: String {
        switch self {
        case .expanded: String(localized: "Expanded")
        case .collapsed: String(localized: "Collapsed")
        }
    }
}

enum AppPreferences {
    static let defaultCodeFontSize = 12.0
    static let defaultToolbarLabelStyle: ToolbarLabelStyle = .titleAndIcon

    static func restoresSession(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: PreferenceKey.restoreSession.rawValue) as? Bool ?? true
    }

    static func codeFontSize(in defaults: UserDefaults = .standard) -> CGFloat {
        let value = defaults.object(forKey: PreferenceKey.codeFontSize.rawValue) as? Double ?? defaultCodeFontSize
        return CGFloat(min(18, max(11, value.isFinite ? value : defaultCodeFontSize)))
    }
}

@MainActor
enum LaunchAtLoginPreferences {
    static func configureDefault(in defaults: UserDefaults = .standard,
                                 status: SMAppService.Status = SMAppService.mainApp.status,
                                 register: () throws -> Void = { try SMAppService.mainApp.register() }) throws {
        guard !defaults.bool(forKey: PreferenceKey.launchAtLoginConfigured.rawValue) else { return }
        switch status {
        case .notRegistered:
            try register()
        case .enabled, .requiresApproval:
            break
        case .notFound:
            return
        @unknown default:
            return
        }
        rememberUserChoice(in: defaults)
    }

    static func rememberUserChoice(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: PreferenceKey.launchAtLoginConfigured.rawValue)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = InterfaceLanguageSession.shared
        Self.applyAppearance()
        if ProcessInfo.processInfo.environment["FOLDGIT_TESTING"] != "1" {
            do {
                try LaunchAtLoginPreferences.configureDefault()
            } catch {
                NSLog("Unable to enable launch at login: %@", error.localizedDescription)
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(toolbarWillAddItem(_:)),
            name: NSToolbar.willAddItemNotification,
            object: nil
        )
        NSApp.windows.compactMap(\.toolbar).forEach(Self.configureToolbarSeparators)
        Task { @MainActor in
            await Task.yield()
            Self.maximizeStartupWindows()
        }
    }

    func applicationDidFinishRestoringWindows(_ notification: Notification) {
        Self.maximizeStartupWindows()
    }

    private static func maximizeStartupWindows() {
        guard ProcessInfo.processInfo.environment["FOLDGIT_TESTING"] != "1" else { return }
        for window in NSApp.windows where window.canBecomeMain && !(window is NSPanel) {
            guard !window.styleMask.contains(.fullScreen), let screen = window.screen ?? NSScreen.main else { continue }
            window.setFrame(screen.visibleFrame, display: true)
        }
    }

    @objc private func toolbarWillAddItem(_ notification: Notification) {
        guard let item = notification.userInfo?["item"] as? NSToolbarItem else { return }
        if item is NSTrackingSeparatorToolbarItem { Self.configureToolbarSeparator(item) }
    }

    private static func configureToolbarSeparators(_ toolbar: NSToolbar) {
        for item in toolbar.items where item is NSTrackingSeparatorToolbarItem {
            configureToolbarSeparator(item)
        }
    }

    private static func configureToolbarSeparator(_ item: NSToolbarItem) {
        Task { @MainActor [weak item] in
            await Task.yield()
            item?.isBordered = false
            if let separator = item as? NSTrackingSeparatorToolbarItem, separator.dividerIndex > 0,
               let toolbar = separator.toolbar,
               let index = toolbar.items.firstIndex(where: { $0 === separator }) {
                toolbar.removeItem(at: index)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        UserDefaults.standard.bool(forKey: PreferenceKey.quitAfterLastWindow.rawValue)
    }

    static func applyAppearance() {
        let value = UserDefaults.standard.string(forKey: PreferenceKey.appAppearance.rawValue)
        NSApp.appearance = (value.flatMap(AppAppearance.init(rawValue:)) ?? .automatic).appearance
    }

}
