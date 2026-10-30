import FoldGitCore
import SwiftUI

struct RepositoryCloneSheet: View {
    let parent: URL
    let onCloned: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var remote = ""
    @State private var directoryName = ""
    @State private var isCloning = false
    @State private var isCancelling = false
    @State private var progressLine = ""
    @State private var errorMessage: String?
    @State private var cloneTask: Task<Void, Never>?
    @FocusState private var addressIsFocused: Bool

    private var request: RepositoryCloneRequest {
        RepositoryCloneRequest(parent: parent, remote: remote, directoryName: directoryName)
    }

    private var progress: Double? {
        guard let range = progressLine.range(of: #"\d+(?=%)"#, options: .regularExpression),
              let percent = Double(progressLine[range]) else { return nil }
        return min(1, max(0, percent / 100))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Clone Remote Repository").font(.headline)
            Form {
                LabeledContent("Save Location") {
                    Text(parent.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                TextField("Repository Address", text: $remote, prompt: Text("HTTPS or SSH repository address"))
                    .focused($addressIsFocused)
                    .accessibilityIdentifier("cloneRepositoryAddress")
                TextField("Folder Name", text: $directoryName)
                    .accessibilityIdentifier("cloneDirectoryName")
            }
            .textFieldStyle(.roundedBorder)
            .disabled(isCloning)
            Text(request.destination.path)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            if isCloning {
                VStack(alignment: .leading, spacing: 8) {
                    Text(isCancelling ? String(localized: "Canceling Clone") : String(localized: "Cloning Repository"))
                    if let progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    if !progressLine.isEmpty {
                        Text(progressLine).font(.caption.monospaced()).lineLimit(2)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("cloneProgress")
            }
            if let errorMessage {
                ScrollView {
                    Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
                .accessibilityIdentifier("cloneError")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    if isCloning {
                        isCancelling = true
                        cloneTask?.cancel()
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isCancelling)
                Button("Clone", action: startClone)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCloning || remote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || directoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(isCloning)
        .onChange(of: remote) { old, new in
            if directoryName.isEmpty || directoryName == RepositoryCloneRequest.suggestedName(for: old) {
                directoryName = RepositoryCloneRequest.suggestedName(for: new)
            }
            errorMessage = nil
        }
        .onChange(of: directoryName) { errorMessage = nil }
        .onDisappear { cloneTask?.cancel() }
        .task { addressIsFocused = true }
    }

    private func startClone() {
        guard !isCloning else { return }
        let request = request
        errorMessage = nil
        progressLine = ""
        isCloning = true
        cloneTask = Task { @MainActor in
            defer {
                isCloning = false
                isCancelling = false
                cloneTask = nil
            }
            do {
                let url = try await RepositoryClone.run(request) { line in
                    await MainActor.run { progressLine = line }
                }
                onCloned(url)
                dismiss()
            } catch {
                errorMessage = Task.isCancelled
                    ? String(localized: "Clone canceled. You can try again.")
                    : OperationFailure("Clone Remote Repository", error).localizedDescription
            }
        }
    }
}
