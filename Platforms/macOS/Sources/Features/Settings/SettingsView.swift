import AppKit
import FoldGitCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance, comparison, snippets, repositories, applications, about
    var id: Self { self }
    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .appearance: String(localized: "Appearance")
        case .comparison: String(localized: "History and Diffs")
        case .snippets: String(localized: "Commit Messages")
        case .repositories: String(localized: "Repositories")
        case .applications: String(localized: "External Applications")
        case .about: String(localized: "About")
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "paintpalette.fill"
        case .comparison: "rectangle.split.2x1.fill"
        case .snippets: "text.bubble.fill"
        case .repositories: "book.closed.fill"
        case .applications: "square.grid.2x2.fill"
        case .about: "info.circle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .general: .gray
        case .appearance: .indigo
        case .comparison: .orange
        case .snippets: .green
        case .repositories: .blue
        case .applications: .purple
        case .about: .teal
        }
    }
}

@MainActor
enum SettingsLayout {
    static let sidebarFontSize: CGFloat = 13
    static let sidebarWidth: CGFloat = {
        let font = NSFont.systemFont(ofSize: sidebarFontSize, weight: .semibold)
        let titleWidth = SettingsTab.allCases.map {
            ($0.title as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        // Reserve space for the icon, label spacing, list insets and selection padding.
        return max(180, ceil(titleWidth) + 80)
    }()
    static var minimumSize: NSSize {
        NSSize(width: sidebarWidth + 540, height: 520)
    }
    static var initialSize: NSSize {
        NSSize(width: minimumSize.width + 60, height: 600)
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    @ObservationIgnored private let defaults: UserDefaults
    var tab: SettingsTab {
        didSet { defaults.set(tab.rawValue, forKey: PreferenceKey.lastSettingsTab.rawValue) }
    }

    /// Reopens the category the user last viewed.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tab = defaults.string(forKey: PreferenceKey.lastSettingsTab.rawValue).flatMap(SettingsTab.init(rawValue:)) ?? .general
    }

    func select(_ selected: SettingsTab?) {
        guard let selected else { return }
        tab = selected
    }
}

struct SettingsView: View {
    @State var navigation = SettingsNavigation()
    private var tab: SettingsTab { navigation.tab }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: Binding<SettingsTab?>(get: { tab }, set: { navigation.select($0) })) {
                ForEach(SettingsTab.allCases) { tab in
                    Label {
                        Text(tab.title)
                            .font(.system(size: SettingsLayout.sidebarFontSize))
                            .fixedSize(horizontal: true, vertical: false)
                    } icon: {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(tab.tint.gradient, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .tag(tab)
                    .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                    .accessibilityIdentifier("settingsCategory-\(tab.rawValue)")
                }
            }
            .listStyle(.sidebar)
            .controlSize(.small)
            .environment(\.defaultMinListRowHeight, 28)
            .scrollEdgeEffectStyle(.soft, for: .all)
            .navigationTitle("Settings")
            .frame(minWidth: SettingsLayout.sidebarWidth)
            .navigationSplitViewColumnWidth(
                min: SettingsLayout.sidebarWidth,
                ideal: SettingsLayout.sidebarWidth,
                max: max(280, SettingsLayout.sidebarWidth)
            )
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch tab {
                case .general: GeneralSettingsPane()
                case .appearance: AppearanceSettingsPane()
                case .comparison: ComparisonSettingsPane()
                case .snippets: CommitMessageSnippetView()
                case .repositories: RepositorySettingsPane()
                case .applications: ApplicationSettingsPane()
                case .about: AboutSettingsPane()
                }
            }
            .navigationTitle(tab.title)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Settings")
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: SettingsLayout.minimumSize.width, minHeight: SettingsLayout.minimumSize.height)
    }
}

struct GeneralSettingsPane: View {
    var languageSession = InterfaceLanguageSession.shared
    @AppStorage(PreferenceKey.interfaceLanguage.rawValue) private var language = InterfaceLanguage.automatic
    @AppStorage(PreferenceKey.restoreSession.rawValue) private var restoreSession = true
    @AppStorage(PreferenceKey.checkForUpdatesAtLaunch.rawValue) private var checkForUpdatesAtLaunch = true
    @AppStorage(PreferenceKey.quitAfterLastWindow.rawValue) private var quitAfterLastWindow = false
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var changingLoginItem = false
    @State private var error: Error?
    @State private var showsLanguageRestart = false
    @State private var isRestarting = false
    @State private var showsRestoreDefaults = false
    @State private var isShowingRestoreDefaults = false
    @State private var didRestoreDefaults = false

    var body: some View {
        Form {
            Section {
                Picker("Interface Language", selection: $language) {
                    ForEach(InterfaceLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("interfaceLanguagePicker")
                .disabled(isRestarting)
            } header: {
                Text("Language")
            } footer: {
                if languageSession.requiresRestart(for: language) {
                    Button("Restart Now") { restartApplication() }
                        .disabled(isRestarting)
                        .accessibilityIdentifier("restartForLanguageButton")
                }
            }
            Section("Startup") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: { enabled in Task { await setLaunchAtLogin(enabled) } }
                ))
                .disabled(changingLoginItem)
                .accessibilityIdentifier("launchAtLoginToggle")
                if loginStatus == .requiresApproval {
                    Text("Allow FoldGit in System Settings to finish enabling launch at login.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                }
                Toggle("Restore Previous Repository and Window", isOn: $restoreSession)
                    .accessibilityIdentifier("restoreSessionToggle")
                Toggle("Check for Updates at Launch", isOn: $checkForUpdatesAtLaunch)
                    .accessibilityIdentifier("checkForUpdatesAtLaunchToggle")
                    .onChange(of: checkForUpdatesAtLaunch) { _, enabled in
                        UpdateChecker.shared.setAutomaticChecks(enabled)
                    }
            }
            Section("Windows") {
                Toggle("Quit When the Last Window Closes", isOn: $quitAfterLastWindow)
                    .accessibilityIdentifier("quitAfterLastWindowToggle")
            }
            Section {
                Button("Restore Defaults…", role: .destructive) {
                    isShowingRestoreDefaults = true
                    showsRestoreDefaults = true
                }
                .accessibilityIdentifier("restoreDefaultsButton")
            }
        }
        .settingsForm()
        .onChange(of: language) {
            language.apply()
            if !isShowingRestoreDefaults {
                showsLanguageRestart = languageSession.requiresRestart(for: language)
            }
        }
        .sheet(isPresented: $showsRestoreDefaults, onDismiss: {
            isShowingRestoreDefaults = false
            loginStatus = SMAppService.mainApp.status
            if didRestoreDefaults {
                didRestoreDefaults = false
                showsLanguageRestart = languageSession.requiresRestart(for: language)
            }
        }) {
            RestoreDefaultsSheet(onRestored: { didRestoreDefaults = true })
        }
        .alert("Restart to Apply Language", isPresented: $showsLanguageRestart) {
            Button("Restart Now") { restartApplication() }
            Button("Later", role: .cancel) {}
        } message: {
            Text("Your language choice has been saved. Restart FoldGit to update the interface and menus.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
        }
        .errorSheet($error, operation: "Save Settings")
    }

    private func restartApplication() {
        isRestarting = true
        do {
            try ApplicationRelauncher.restart()
        } catch {
            isRestarting = false
            self.error = OperationFailure("Restart FoldGit", error)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) async {
        changingLoginItem = true
        defer {
            loginStatus = SMAppService.mainApp.status
            changingLoginItem = false
        }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try await SMAppService.mainApp.unregister() }
            LaunchAtLoginPreferences.rememberUserChoice()
        } catch { self.error = OperationFailure("Launch at Login", error) }
    }
}

struct AppearanceSettingsPane: View {
    @AppStorage(PreferenceKey.appAppearance.rawValue) private var appearance = AppAppearance.automatic
    @AppStorage(PreferenceKey.toolbarLabelStyle.rawValue) private var toolbarStyle = AppPreferences.defaultToolbarLabelStyle

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Color Scheme", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("colorSchemePicker")
            }
            Section("Toolbar") {
                Picker("Toolbar Display", selection: Binding(
                    get: { toolbarStyle != .iconOnly },
                    set: { toolbarStyle = $0 ? .titleAndIcon : .iconOnly }
                )) {
                    Text("Icons Only").tag(false)
                    Text("Icons and Text").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("toolbarDisplayPicker")
            }
        }
        .settingsForm()
        .onChange(of: appearance) { AppDelegate.applyAppearance() }
    }
}

struct ComparisonSettingsPane: View {
    @AppStorage(PreferenceKey.showCommitGraph.rawValue) private var showGraph = true
    @AppStorage(PreferenceKey.commitTimeDisplayMode.rawValue) private var commitTimeMode = AppPreferences.defaultCommitTimeDisplayMode
    @AppStorage(PreferenceKey.diffLayout.rawValue) private var layout = DiffLayout.automatic
    @AppStorage(PreferenceKey.diffFileExpansion.rawValue) private var fileExpansion = AppPreferences.defaultDiffFileExpansion
    @AppStorage(PreferenceKey.codeFontSize.rawValue) private var fontSize = AppPreferences.defaultCodeFontSize
    @AppStorage(PreferenceKey.wrapLongLines.rawValue) private var wrapLongLines = false

    var body: some View {
        Form {
            Section {
                Toggle("Show Commit Graph", isOn: $showGraph)
                    .accessibilityIdentifier("showCommitGraphToggle")
                Picker("Commit Time", selection: $commitTimeMode) {
                    ForEach(CommitTimeDisplayMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("commitTimeDisplayModePicker")
            } header: {
                Text("Commit History")
            } footer: {
                Text("Hybrid: relative times within 7 days, exact dates before that.")
            }
            Section("Diff Display") {
                Picker("Diff Layout", selection: $layout) {
                    ForEach(DiffLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settingsDiffLayoutPicker")
                Picker("Default File Expansion", selection: $fileExpansion) {
                    ForEach(DiffFileExpansion.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("defaultDiffFileExpansionPicker")
            }
            Section("Code Display") {
                LabeledContent("Code Font Size") {
                    HStack {
                        Slider(value: $fontSize, in: 11...18, step: 1)
                            .frame(minWidth: 100, idealWidth: 150, maxWidth: 180)
                            .accessibilityLabel(Text("Code Font Size"))
                            .accessibilityIdentifier("codeFontSizeSlider")
                        Text("\(Int(fontSize)) pt").monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
                Toggle("Wrap Long Lines", isOn: $wrapLongLines)
                    .accessibilityIdentifier("wrapLongLinesToggle")
                // Kept next to the code options so font and wrapping changes are visible immediately.
                ChunkView(chunk: Self.preview, filePath: "Example.swift")
                    .accessibilityLabel(Text("Preview"))
            }
        }
        .settingsForm()
        .onChange(of: commitTimeMode) { CommitTimeClock.shared.refresh() }
    }

    private static let preview = Chunk(raw: "@@ -1,3 +1,3 @@\n func greeting() {\n-    let message = \"Hello\"\n+    let message = \"Welcome to FoldGit\"\n }")
}

struct RepositorySettingsPane: View {
    @AppStorage(PreferenceKey.showWorktreeInformation.rawValue)
    private var showWorktreeInformation = PreferenceDefaults.showWorktreeInformation
    @AppStorage(PreferenceKey.showWorktreeStatus.rawValue) private var showWorktreeStatus = PreferenceDefaults.showWorktreeStatus
    @AppStorage(PreferenceKey.folder.rawValue) private var data: Data?
    @State private var autoFetch = AutoFetchScheduler.shared
    @State private var error: Error?
    private var folders: [WorkspaceEntry] { data.flatMap { try? JSONDecoder().decode([WorkspaceEntry].self, from: $0) } ?? [] }
    private var groups: [WorkspaceEntry] { folders.filter { !$0.repositories.isEmpty } }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Worktrees", isOn: $showWorktreeInformation)
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("showWorktreeInformationToggle")
                Toggle("Show Worktree Status in Sidebar", isOn: $showWorktreeStatus)
                    .toggleStyle(.switch)
                    .disabled(!showWorktreeInformation)
                    .accessibilityIdentifier("showWorktreeStatusToggle")
            } header: {
                Text("Worktrees")
            } footer: {
                Text("Also enable worktrees per repository from its context menu.")
            }
            Section {
                Picker("Default Interval", selection: Binding(get: { autoFetch.defaultInterval }, set: {
                    autoFetch.setDefaultInterval($0)
                })) {
                    ForEach(AutoFetchInterval.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("defaultAutoFetchIntervalPicker")
            } header: {
                Text("Automatic Fetch")
            } footer: {
                Text("Repositories without their own interval use the default.")
            }
            if groups.isEmpty {
                Section { Text("No Repositories").foregroundStyle(.secondary) }
            }
            ForEach(groups, id: \.url) { entry in
                Section(entry.displayName) {
                    ForEach(entry.repositories, id: \.url) { repository in
                        VStack(alignment: .leading, spacing: 6) {
                            Picker(selection: Binding(get: { autoFetch.override(for: repository) }, set: {
                                autoFetch.setInterval($0, for: repository)
                            })) {
                                AutoFetchIntervalOptions(defaultInterval: autoFetch.defaultInterval)
                            } label: {
                                Text(verbatim: repository.displayName)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            .pickerStyle(.menu)
                            let key = AutoFetchScheduler.key(for: repository.url)
                            if autoFetch.fetching.contains(key) {
                                Label("Fetching", systemImage: "arrow.clockwise")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if let reason = autoFetch.errors[key] {
                                Button {
                                    error = OperationFailure("Automatic Fetch", GenericError(errorDescription: reason), directory: repository.url)
                                } label: {
                                    Label(reason, systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange)
                                    .lineLimit(2)
                                }
                                .buttonStyle(.borderless).help("View Error Details")
                            } else if let date = autoFetch.lastSuccess[key] {
                                HStack {
                                    Text("Last Successful Fetch")
                                    Text(date, format: .dateTime.month().day().hour().minute())
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .help(repository.url.path)
                    }
                }
            }
        }
        .settingsForm()
        .errorSheet($error, operation: "Automatic Fetch")
    }
}

struct ApplicationSettingsPane: View {
    @State private var store = OpenInStore()
    @State private var error: Error?
    private let directory = FileManager.default.homeDirectoryForCurrentUser

    var body: some View {
        Form {
            Section {
                ForEach(store.applications.filter { !$0.isFinder }) { application in
                    HStack(spacing: 8) {
                        Image(nsImage: store.icon(for: application))
                            .resizable().frame(width: 24, height: 24)
                            .accessibilityHidden(true)
                        Toggle(isOn: Binding(get: { store.pinnedIDs.contains(application.id) }, set: {
                            store.setPinned($0, application: application)
                        })) { Text(verbatim: application.name) }
                        .toggleStyle(.checkbox)
                        if store.isCustomApplication(application) {
                            Button("Remove", systemImage: "minus") {
                                store.removeCustomApplication(application)
                                Task { await store.reload(for: directory, force: true) }
                            }
                            .labelStyle(.iconOnly)
                            .help("Remove Custom Application")
                        }
                    }
                }
                HStack {
                    Button("Add Application…", systemImage: "plus") { chooseApplication() }
                    Button("Refresh Applications", systemImage: "arrow.clockwise") {
                        Task { await store.reload(for: directory, force: true) }
                    }
                    .disabled(store.isLoading)
                    if store.isLoading { ProgressView().controlSize(.small) }
                }
            } header: {
                Text("Open in")
            } footer: {
                Text("Checked applications are pinned to the top of the Open in menu.")
            }
        }
        .settingsForm()
        .task { await store.reload(for: directory) }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in store.reloadPreferences() }
        .errorSheet($error, operation: "Add Application")
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Add Application")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let application = OpenInApplication.read(at: url), application.id != Bundle.main.bundleIdentifier else {
                error = GenericError(errorDescription: String(localized: "Choose another application to open the project folder."))
                return
            }
            store.addCustomApplication(application)
        }
    }
}

struct AboutSettingsPane: View {
    @ObservedObject private var updateChecker = UpdateChecker.shared
    @State private var showsLicense = false
    private let website = URL(string: "https://foldgit.com")!
    private let project = URL(string: "https://github.com/dufu1991/foldgit")!
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().scaledToFit().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: "FoldGit").font(.title.bold())
                        Text("Version \(version) (\(build))").foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("A native Git client for macOS.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check for Updates") { updateChecker.checkNow() }
                        .disabled(!updateChecker.canCheckForUpdates)
                        .accessibilityIdentifier("checkForUpdatesButton")
                }
            }
            Section("Project") {
                Link("Official Website", destination: website)
                Link("GitHub Repository", destination: project)
                Link("Send Feedback", destination: project.appending(path: "issues"))
                Button("Open Source Licenses…") { showsLicense = true }
            }
        }
        .settingsForm()
        .sheet(isPresented: $showsLicense) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Open Source Licenses").font(.title2.bold())
                ScrollView {
                    Text(verbatim: license).font(.body).textSelection(.enabled)
                }
                HStack { Spacer(); Button("Done") { showsLicense = false }.keyboardShortcut(.defaultAction) }
            }
            .padding(24).frame(width: 600, height: 500)
        }
    }

    private var license: String {
        guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }
}

extension View {
    func settingsForm() -> some View {
        self.formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 8, for: .scrollContent)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .toggleStyle(.switch)
    }
}
