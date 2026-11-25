import SwiftUI

struct OpenInMenu: View {
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
            Button("Manage External Applications", systemImage: "gearshape") {
                SettingsWindowController.show(tab: .applications)
            }
        } label: {
            Label("Open in", systemImage: "arrow.up.forward.app")
        }
        .help("Open Current Repository in Another Application")
        .disabled(store.isOpening)
    }

    private func applicationButton(_ application: OpenInApplication) -> some View {
        Button {
            Task {
                do {
                    try await store.open(application, directory: directory)
                } catch {
                    onError(OperationFailure("Open in", error))
                }
            }
        } label: {
            Label {
                Text(verbatim: application.name)
            } icon: {
                Image(nsImage: store.icon(for: application))
                    .renderingMode(.original)
                    .resizable()
                    .frame(width: 16, height: 16)
            }
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
        .onChange(of: store.customApplicationPaths) {
            Task { await store.reload(for: directory) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openInApplicationsDidRefresh)) { _ in
            // Settings has just rescanned. The shared discovery cache serves this directory or rescans a different one.
            Task { await store.reload(for: directory) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsDidRestoreDefaults)) { _ in
            Task { await store.reload(for: directory, force: true) }
        }
    }
}
