import FoldGitCore
import SwiftUI

struct ProjectAutoFetchMenu: View {
    let folder: WorkspaceEntry
    var autoFetch: AutoFetchScheduler = .shared

    var body: some View {
        Menu {
            Picker("Automatic Fetch", selection: Binding(
                get: { autoFetch.interval(for: folder) },
                set: { autoFetch.setInterval($0, for: folder) }
            )) {
                ForEach(AutoFetchInterval.allCases) { interval in
                    Text(interval.title).tag(interval)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label("Automatic Fetch", systemImage: "clock.arrow.circlepath")
        }
    }
}

struct ProjectAutoFetchWarning: View {
    let folder: WorkspaceEntry
    let repositoryName: String
    let message: String
    let onError: (Error) -> Void
    @State private var confirmingFetch = false
    @State private var isFetching = false

    var body: some View {
        Button {
            confirmingFetch = true
        } label: {
            if isFetching {
                ProgressView().controlSize(.small).frame(width: 20, height: 20)
            } else {
                Image(systemName: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange)
                    .padding(4).contentShape(Rectangle())
            }
        }
        .buttonStyle(.borderless)
        .disabled(isFetching || AutoFetchScheduler.shared.fetching.contains(AutoFetchScheduler.key(for: folder.url)))
        .immediateHelp(String(localized: "Automatic fetch failed. Click to retry."))
        .accessibilityLabel(Text("Automatic Fetch Failed"))
        .accessibilityValue(Text(verbatim: message))
        .accessibilityIdentifier("autoFetchWarning-" + folder.identity.path)
        .alert("Automatic Fetch Failed", isPresented: $confirmingFetch) {
            Button("Cancel", role: .cancel) {}
            Button("Fetch Now", action: fetchNow)
        } message: {
            Text(verbatim: repositoryName + "\n\n" + message + "\n\n" + String(localized: "We recommend fetching again now. Continue?"))
        }
    }

    private func fetchNow() {
        guard !isFetching else { return }
        isFetching = true
        Task {
            defer { isFetching = false }
            do {
                try await RemoteUpdateService.shared.execute(GitFetch(directory: folder.url))
                AutoFetchScheduler.shared.recordFetchSuccess(for: folder.url)
                NotificationCenter.default.post(name: .projectAutoFetchDidFinish,
                                                object: AutoFetchEvent(directory: folder.url, error: nil))
            } catch {
                onError(OperationFailure("Fetch", error, directory: folder.url))
            }
        }
    }
}
