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
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Open \(fileURL?.absoluteString ?? "")")
        .disabled(fileURL == nil)
    }
}
