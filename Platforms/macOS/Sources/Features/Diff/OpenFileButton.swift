//
//  OpenFileButton.swift
//  FoldGit
//

import SwiftUI

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
        .disabled(fileURL == nil)
        .errorSheet($error, operation: "Open File")
    }
}
