//
//  OpenFileButton.swift
//  FoldGit
//

import SwiftUI

struct OpenFileButton: View {
    @Environment(\.folder) private var folder

    var filePath: String

    private var fileURL: URL? {
        folder?.appending(path: filePath)
    }

    var body: some View {
        Button {
            if let fileURL {
                NSWorkspace.shared.open(fileURL)
            }
        } label: {
            Image(systemName: "arrow.up.right")
                .foregroundStyle(.secondary)
                .frame(width: 12, height: 12)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Open \(fileURL?.absoluteString ?? "")")
        .disabled(fileURL == nil)
    }
}
