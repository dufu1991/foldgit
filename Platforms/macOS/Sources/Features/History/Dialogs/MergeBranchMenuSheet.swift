import FoldGitCore
import SwiftUI

struct MergeBranchMenuSheet: View {
    let directory: URL
    let currentBranch: String?
    let onMerge: (Branch) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var branches: [Branch] = []
    @State private var selection: String?
    @State private var isLoading = true
    @State private var error: Error?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Merge Branch").font(.headline)
            if let currentBranch { Text("Merge into \"\(currentBranch)\"").foregroundStyle(.secondary) }
            List(branches, selection: $selection) { branch in
                Text(verbatim: branch.name).tag(branch.name)
            }
            .overlay {
                if isLoading { ProgressView() }
                else if branches.isEmpty { Text("No Results").foregroundStyle(.secondary) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Merge") {
                    guard let branch = branches.first(where: { $0.name == selection }) else { return }
                    onMerge(branch)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil || isLoading)
            }
        }
        .padding(20)
        .frame(width: 420, height: 400)
        .task {
            defer { isLoading = false }
            do {
                async let local = GitRuntime.run(GitBranch(directory: directory))
                async let remote = GitRuntime.run(GitBranch(directory: directory, isRemote: true))
                let available = try await local + remote
                guard !Task.isCancelled else { return }
                branches = available.filter { !$0.isCurrent && !$0.isDetached && !$0.name.contains(" -> ") }
            } catch { self.error = error }
        }
        .errorSheet($error, operation: "Load Branches")
    }
}
