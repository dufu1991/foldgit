import AppKit
import FoldGitCore
import Foundation
import SwiftUI
import Testing
@testable import FoldGit

@MainActor
struct LocalizationTests {
    private let translations = [
        "en": "Commit",
        "zh-Hans": "提交",
        "zh-Hant": "提交",
        "ja": "コミット",
        "ko": "커밋",
        "ru": "Создать коммит",
        "fr": "Créer un commit",
        "es": "Crear commit",
    ]

    @Test func languageRestartStateSurvivesClosingSettingsAndClearsAfterRelaunch() throws {
        let name = "FoldGit.LanguageSession.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let session = InterfaceLanguageSession(defaults: defaults)
        #expect(!session.requiresRestart(for: .automatic))
        for language in InterfaceLanguage.allCases where language != .automatic {
            defaults.set(language.rawValue, forKey: PreferenceKey.interfaceLanguage.rawValue)
            language.apply(to: defaults)
            #expect(session.requiresRestart(for: language))
            #expect(!session.requiresRestart(for: .automatic))
            let relaunched = InterfaceLanguageSession(defaults: defaults)
            #expect(!relaunched.requiresRestart(for: language))
            #expect(relaunched.requiresRestart(for: .automatic))
        }
    }

    @Test func restartHelperWaitsForOldProcessAndPreservesLiteralApplicationPath() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FoldGit-Relaunch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("Application with spaces ' $() and quotes.app")
        let oldProcess = Process()
        oldProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        oldProcess.arguments = ["30"]
        try oldProcess.run()
        defer { if oldProcess.isRunning { oldProcess.terminate() } }
        let helper = ApplicationRelauncher.makeRestartProcess(waitingFor: oldProcess.processIdentifier,
                                                             applicationURL: marker,
                                                             openerURL: URL(fileURLWithPath: "/usr/bin/touch"))
        try helper.run()
        defer { if helper.isRunning { helper.terminate() } }
        try await Task.sleep(for: .milliseconds(200))
        #expect(helper.isRunning)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        oldProcess.terminate()
        oldProcess.waitUntilExit()
        helper.waitUntilExit()
        #expect(helper.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
    }

    @Test func translatedResourcesAreBundled() throws {
        for (language, expected) in translations {
            let bundle = try localizedBundle(language)
            #expect(bundle.localizedString(forKey: "Commit", value: nil, table: nil) == expected)
        }
    }

    @Test func russianCommitCountsUsePluralRules() throws {
        let bundle = try localizedBundle("ru")
        let expected = [0: "0 коммитов", 1: "1 коммит", 2: "2 коммита", 5: "5 коммитов", 21: "21 коммит", 22: "22 коммита"]
        for (count, text) in expected {
            let localized = String(localized: "\(count) commits", bundle: bundle, locale: Locale(identifier: "ru"))
            #expect(localized == text)
        }
    }

    @Test func untrackedCountsUseChineseWordOrder() throws {
        let bundle = try localizedBundle("zh-Hans")
        for count in [1, 2, 100] {
            let localized = String(localized: "\(count) untracked files", bundle: bundle, locale: Locale(identifier: "zh-Hans"))
            #expect(localized == "\(count) 个未跟踪文件")
        }
    }

    @Test func behindCommitCountsUseLocalizedPluralRules() throws {
        let expectations = [
            "en": [1: "Behind by 1 commit", 4: "Behind by 4 commits"],
            "zh-Hans": [0: "落后 0 次提交", 4: "落后 4 次提交"],
            "zh-Hant": [4: "落後 4 次提交"],
            "ru": [1: "Отставание на 1 коммит", 2: "Отставание на 2 коммита", 5: "Отставание на 5 коммитов"],
        ]
        for (language, counts) in expectations {
            let bundle = try localizedBundle(language)
            for (count, expected) in counts {
                let actual = String(localized: "Behind by \(count) commits", bundle: bundle, locale: Locale(identifier: language))
                #expect(actual == expected)
            }
        }
    }

    @Test func shortStatisticsPreserveEmptyAndUnknownOutput() {
        #expect(GitSummary.shortStat("").isEmpty)
        #expect(GitSummary.shortStat("Binary files differ") == "Binary files differ")
    }

    @Test func largeWorkingTreeStatisticsKeepGroupedNumbersIntact() {
        let statistics = DiffStat(files: Array(repeating: "file", count: 149),
                                  insertions: [1_143] + Array(repeating: 0, count: 148),
                                  deletions: [2_073] + Array(repeating: 0, count: 148))
        let insertions = 1_143
        let deletions = 2_073
        let result = GitSummary.describe(statistics)
        #expect(result.contains(String(localized: "\(insertions) insertions")))
        #expect(result.contains(String(localized: "\(deletions) deletions")))
    }

    @Test func shortStatisticsUseLocalizedCounts() {
        let result = GitSummary.shortStat(" 1 file changed, 2 insertions(+), 3 deletions(-)\n")
        let files = 1
        let insertions = 2
        let deletions = 3
        #expect(result.contains(String(localized: "\(files) files changed")))
        #expect(result.contains(String(localized: "\(insertions) insertions")))
        #expect(result.contains(String(localized: "\(deletions) deletions")))
        #expect(!result.contains("(+)"))
        #expect(!result.contains("(-)"))
    }

    @Test func translatedSheetsRenderAtCompactWidths() async throws {
        let outputDirectory = ProcessInfo.processInfo.environment["LOCALIZATION_SNAPSHOT_DIRECTORY"]
        for language in translations.keys.sorted() {
            let sheet = CreateNewTagSheet(
                folder: WorkspaceEntry(url: URL(fileURLWithPath: "/tmp")),
                showingCreateNewTagAt: .constant(nil),
                onCreate: {}
            )
            .environment(\.locale, Locale(identifier: language))
            .frame(width: 520)
            .background(Color(nsColor: .windowBackgroundColor))
            let view = NSHostingView(rootView: sheet)
            let size = view.fittingSize
            #expect(size.width <= 520)
            #expect(size.height < 600)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderBack(nil)
            defer { window.close() }
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            window.displayIfNeeded()
            if let outputDirectory {
                let directory = URL(fileURLWithPath: outputDirectory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: image)
                let png = try #require(image.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("tag-sheet-\(language).png"))
            }
        }
    }

    private func localizedBundle(_ language: String) throws -> Bundle {
        let url = try #require(Bundle.main.url(forResource: language, withExtension: "lproj"))
        return try #require(Bundle(url: url))
    }
}
