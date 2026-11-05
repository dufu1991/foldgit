//
//  OpenFileButton.swift
//  FoldGit
//

import SwiftUI

struct ViewWorkingTreeFileButton: View {
    @Environment(\.openWorkspaceFile) private var openWorkspaceFile
    @State private var isMissing = false
    var filePath: String

    var body: some View {
        if let openWorkspaceFile {
            Button("View Working Tree File", systemImage: "doc.text.magnifyingglass") {
                isMissing = !openWorkspaceFile(filePath)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .controlSize(.small)
            .help("View Working Tree File")
            .accessibilityIdentifier("viewWorkingTreeFile-" + filePath)
            .alert("File No Longer Exists", isPresented: $isMissing) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(verbatim: String(localized: "The selected file is no longer available in the working tree.")
                     + "\n\n" + filePath)
            }
        }
    }
}

struct OpenFileButton: View {
    @Environment(\.folder) private var folder
    @State private var error: Error?

    var filePath: String

    private var fileURL: URL? {
        folder?.appending(path: filePath)
    }

    var body: some View {
        Button {
            if let fileURL {
                error = FileOpening.open(fileURL, using: NSWorkspace.shared.open)
            }
        } label: {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .help("Open \(fileURL?.absoluteString ?? "")")
        .accessibilityLabel("Open File")
        .disabled(fileURL == nil)
        .errorSheet($error, operation: "Open File")
    }
}
