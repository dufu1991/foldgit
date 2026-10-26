//
//  FolderTests.swift
//  FoldGitTests
//

import Foundation
import Testing
@testable import FoldGitCore

struct FolderTests {

    @Test
    func encodeDecodePreservesFolderOrder() throws {
        let urls = [
            URL(fileURLWithPath: "/projects/alpha"),
            URL(fileURLWithPath: "/projects/beta"),
            URL(fileURLWithPath: "/projects/gamma"),
        ]
        let folders = urls.map { WorkspaceEntry(url: $0) }

        let data = try JSONEncoder().encode(folders)
        let decoded = try JSONDecoder().decode([WorkspaceEntry].self, from: data)

        #expect(decoded.map(\.url) == urls)
    }

    @Test
    func moveThenEncodeDecodePreservesReorderedFolders() throws {
        let urls = [
            URL(fileURLWithPath: "/projects/alpha"),
            URL(fileURLWithPath: "/projects/beta"),
            URL(fileURLWithPath: "/projects/gamma"),
        ]
        var folders = urls.map { WorkspaceEntry(url: $0) }
        folders = folders.movingElements(at: [2], to: 0)

        let data = try JSONEncoder().encode(folders)
        let decoded = try JSONDecoder().decode([WorkspaceEntry].self, from: data)

        #expect(decoded.map(\.url) == [urls[2], urls[0], urls[1]])
    }
}
