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
