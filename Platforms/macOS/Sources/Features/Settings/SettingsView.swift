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
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .comparison: "rectangle.split.2x1"
        case .snippets: "text.badge.plus"
        case .repositories: "folder.badge.gearshape"
        case .applications: "arrow.up.forward.app"
        case .about: "info.circle"
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    var tab: SettingsTab = .general

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
                            .font(.system(size: 13))
                    } icon: {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 14, weight: .regular))
                            .imageScale(.medium)
                            .frame(width: 18, height: 18)
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
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 220)
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
        .frame(minWidth: 720, minHeight: 520)
    }
}

struct GeneralSettingsPane: View {
    var languageSession = InterfaceLanguageSession.shared
    @AppStorage(PreferenceKey.interfaceLanguage.rawValue) private var language = InterfaceLanguage.automatic
    @AppStorage(PreferenceKey.restoreSession.rawValue) private var restoreSession = true
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
                VStack(alignment: .leading, spacing: 8) {
                    Text("Language changes take full effect after restarting the application.")
                    if languageSession.requiresRestart(for: language) {
                        Button("Restart Now") { restartApplication() }
                            .disabled(isRestarting)
                            .accessibilityIdentifier("restartForLanguageButton")
                    }
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
            }
            Section {
                Toggle("Quit When the Last Window Closes", isOn: $quitAfterLastWindow)
                    .accessibilityIdentifier("quitAfterLastWindowToggle")
            } header: {
                Text("Windows")
            } footer: {
                Text("Automatic fetch continues while the application is running.")
            }
            Section {
                Button("Restore Defaults", role: .destructive) {
                    isShowingRestoreDefaults = true
                    showsRestoreDefaults = true
                }
                .accessibilityIdentifier("restoreDefaultsButton")
            } header: {
                Text("Reset Settings")
            } footer: {
                Text("Review all default values before restoring settings.")
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
        .errorSheet($error)
    }

    private func restartApplication() {
        isRestarting = true
        do {
            try ApplicationRelauncher.restart()
        } catch {
            isRestarting = false
            self.error = error
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
        } catch { self.error = error }
    }
}

struct AppearanceSettingsPane: View {
    @AppStorage(PreferenceKey.appAppearance.rawValue) private var appearance = AppAppearance.automatic
    @AppStorage(PreferenceKey.toolbarLabelStyle.rawValue) private var toolbarStyle = AppPreferences.defaultToolbarLabelStyle

    var body: some View {
        Form {
            Section("Appearance") {
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
    @AppStorage(PreferenceKey.diffLayout.rawValue) private var layout = DiffLayout.automatic
    @AppStorage(PreferenceKey.diffFileExpansion.rawValue) private var fileExpansion = DiffFileExpansion.expanded
    @AppStorage(PreferenceKey.codeFontSize.rawValue) private var fontSize = AppPreferences.defaultCodeFontSize
    @AppStorage(PreferenceKey.wrapLongLines.rawValue) private var wrapLongLines = false

    var body: some View {
        Form {
            Section("Commit History") {
                Toggle("Show Commit Graph", isOn: $showGraph)
                    .accessibilityIdentifier("showCommitGraphToggle")
            }
            Section {
                Picker("Diff Layout", selection: $layout) {
                    ForEach(DiffLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settingsDiffLayoutPicker")
            } header: {
                Text("Diff Display")
            } footer: {
                Text("Automatic uses side-by-side layout when there is enough space.")
                Text("Layout changes are shared with the controls in the diff view.")
            }
            Section {
                Picker("Default File Expansion", selection: $fileExpansion) {
                    ForEach(DiffFileExpansion.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("defaultDiffFileExpansionPicker")
            } header: {
                Text("Files")
            } footer: {
                Text("Applies to newly opened diffs. Files you expand or collapse manually keep their state.")
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
            }
            Section {
                ChunkView(chunk: Self.preview, filePath: "Example.swift")
            } header: { Text("Preview") }
        }
        .settingsForm()
    }

    private static let preview = Chunk(raw: "@@ -1,3 +1,3 @@\n func greeting() {\n-    let message = \"Hello\"\n+    let message = \"Welcome to FoldGit\"\n }")
}

struct RepositorySettingsPane: View {
    @AppStorage(PreferenceKey.showWorktreeInformation.rawValue)
    private var showWorktreeInformation = PreferenceDefaults.showWorktreeInformation
    @AppStorage(PreferenceKey.folder.rawValue) private var data: Data?
    @State private var autoFetch = AutoFetchScheduler.shared
    private var folders: [WorkspaceEntry] { data.flatMap { try? JSONDecoder().decode([WorkspaceEntry].self, from: $0) } ?? [] }
    private var groups: [WorkspaceEntry] { folders.filter { !$0.repositories.isEmpty } }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Worktrees", isOn: $showWorktreeInformation)
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("showWorktreeInformationToggle")
            } header: {
                Text("Worktrees")
            } footer: {
                Text("After enabling worktrees globally, enable them for each repository in its context menu. Worktree information and management actions appear only for enabled repositories. Turning this off preserves repository choices.")
            }
            Section("Automatic Fetch") {
                Text("Choose a fetch interval for each repository. Fetch downloads remote updates without merging them.")
                    .foregroundStyle(.secondary)
            }
            if groups.isEmpty {
                Section { Text("No Repositories").foregroundStyle(.secondary) }
            }
            ForEach(groups, id: \.url) { entry in
                Section(entry.displayName) {
                    ForEach(entry.repositories, id: \.url) { repository in
                        VStack(alignment: .leading, spacing: 6) {
                            Picker(selection: Binding(get: { autoFetch.interval(for: repository) }, set: {
                                autoFetch.setInterval($0, for: repository)
                            })) {
                                ForEach(AutoFetchInterval.allCases) { Text($0.title).tag($0) }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: repository.displayName)
                                    Text(verbatim: repository.url.path)
                                        .font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                            }
                            .pickerStyle(.menu)
                            let key = AutoFetchScheduler.key(for: repository.url)
                            if autoFetch.fetching.contains(key) {
                                Label("Fetching", systemImage: "arrow.clockwise")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if let error = autoFetch.errors[key] {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange)
                                    .lineLimit(2).help(error)
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
    }
}

struct ApplicationSettingsPane: View {
    @State private var store = OpenInStore()
    @State private var error: Error?
    private let directory = FileManager.default.homeDirectoryForCurrentUser

    var body: some View {
        Form {
            Section("Open in") {
                Text("Pinned applications appear first in the Open in menu.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Choose Application", systemImage: "plus") { chooseApplication() }
                    Button("Refresh Applications", systemImage: "arrow.clockwise") {
                        Task { await store.reload(for: directory, force: true) }
                    }
                    .disabled(store.isLoading)
                    if store.isLoading { ProgressView().controlSize(.small) }
                }
            }
            Section("Applications") {
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
            }
        }
        .settingsForm()
        .task { await store.reload(for: directory) }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in store.reloadPreferences() }
        .errorSheet($error)
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Application")
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
    @State private var showsLicense = false
    private let project = URL(string: "https://github.com/dufu1991/foldgit")!
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().scaledToFit().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: "FoldGit").font(.title.bold())
                        Text("Version \(version)").foregroundStyle(.secondary)
                        Text("A native Git client for macOS.").foregroundStyle(.secondary)
                    }
                }
            }
            Section("Project") {
                Link("Project Homepage", destination: project)
                Link("Send Feedback", destination: project.appending(path: "issues"))
                Button("Open Source Licenses") { showsLicense = true }
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
