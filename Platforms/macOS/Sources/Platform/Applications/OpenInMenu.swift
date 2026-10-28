import SwiftUI
import UniformTypeIdentifiers

struct OpenInMenu: View {
    private enum SelectionError: LocalizedError {
        case invalidApplication
        var errorDescription: String? { String(localized: "Choose another application to open the project folder.") }
    }

    let directory: URL
    let store: OpenInStore
    let onError: (Error) -> Void

    var body: some View {
        Menu {
            if let finder = store.finder {
                applicationButton(finder)
                Divider()
            }
            if !store.pinned.isEmpty {
                Section("Pinned Applications") {
                    ForEach(store.pinned) { applicationButton($0) }
                }
            }
            ForEach(store.suggested) { applicationButton($0) }
            if !store.others.isEmpty {
                Menu("Other Applications") {
                    ForEach(store.others) { applicationButton($0) }
                }
            }
            if store.isLoading && store.applications.isEmpty {
                Text("Loading Applications")
            }
            Divider()
            Menu("Pin Applications") {
                ForEach(store.applications.filter { !$0.isFinder }) { application in
                    Toggle(isOn: Binding(get: { store.pinnedIDs.contains(application.id) }, set: {
                        store.setPinned($0, application: application)
                    })) {
                        applicationLabel(application)
                    }
                }
            }
            .disabled(store.applications.isEmpty)
            Button("Choose Application", systemImage: "app.badge") { chooseApplication() }
            Button("Refresh Applications", systemImage: "arrow.clockwise") {
                Task { await store.reload(for: directory, force: true) }
            }
            .disabled(store.isLoading)
        } label: {
            Label("Open in", systemImage: "arrow.up.forward.app")
        }
        .help("Open Current Repository in Another Application")
        .disabled(store.isOpening)
    }

    private func applicationLabel(_ application: OpenInApplication) -> some View {
        Label {
            Text(verbatim: application.name)
        } icon: {
            Image(nsImage: store.icon(for: application))
                .renderingMode(.original)
                .resizable()
                .frame(width: 16, height: 16)
        }
    }

    private func applicationButton(_ application: OpenInApplication) -> some View {
        Button { open(application) } label: { applicationLabel(application) }
    }

    private func open(_ application: OpenInApplication, rememberApplication: Bool = false) {
        Task {
            do {
                try await store.open(application, directory: directory, rememberApplication: rememberApplication)
            } catch {
                onError(error)
            }
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Application")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let application = OpenInApplication.read(at: url), application.id != Bundle.main.bundleIdentifier else {
                onError(SelectionError.invalidApplication)
                return
            }
            open(application, rememberApplication: true)
        }
    }
}

extension View {
    /// Keeps an Open in store current for a repository; the owner shares it between the toolbar and the menu bar.
    func loadsApplications(_ store: OpenInStore, for directory: URL) -> some View {
        task(id: directory) { await store.reload(for: directory) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willBecomeActiveNotification)) { _ in
            Task { await store.reload(for: directory, force: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            store.reloadPreferences()
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsDidRestoreDefaults)) { _ in
            Task { await store.reload(for: directory, force: true) }
        }
    }
}
