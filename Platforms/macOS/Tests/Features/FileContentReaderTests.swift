import Darwin
import Foundation
import Testing
@testable import FoldGit

struct FileContentReaderTests {
    @Test func strictEncodingsPreserveUnicodeAndLineEndings() throws {
        let source = "let greeting = \"中文 😀\"\r\n\t// 完整内容\n"
        for data in [Data(source.utf8), Data([0xEF, 0xBB, 0xBF]) + Data(source.utf8),
                     Data([0xFF, 0xFE]) + source.data(using: .utf16LittleEndian)!,
                     Data([0xFE, 0xFF]) + source.data(using: .utf16BigEndian)!] {
            guard case .text(let text, let plain, _) = try FileContentReader.decode(data, plain: false) else {
                Issue.record("Valid text was rejected")
                return
            }
            #expect(text == source)
            #expect(!plain)
            #expect(!text.contains("\u{FFFD}"))
        }
        guard case .text(let text, _, _) = try FileContentReader.decode(Data(), plain: false) else {
            Issue.record("Empty text was rejected")
            return
        }
        #expect(text.isEmpty)
    }

    @Test func invalidEncodingAndBinaryContentAreNeverRepaired() throws {
        for bytes: [UInt8] in [[0xC0, 0xAF], [0xE4, 0xB8], [0xFF, 0xFE, 0x00], [0xFF, 0xFE, 0x00, 0xD8]] {
            guard case .unavailable(.encoding) = try FileContentReader.decode(Data(bytes), plain: false) else {
                Issue.record("Invalid encoding was accepted")
                return
            }
        }
        for bytes: [UInt8] in [[65, 0, 66], [0x89, 0x50, 0x4E, 0x47], [1, 2, 3]] {
            guard case .unavailable = try FileContentReader.decode(Data(bytes), plain: false) else {
                Issue.record("Binary data was accepted")
                return
            }
        }
    }

    @Test func lineLimitsCountCRLFOnceAndMeasureUTF16Units() throws {
        let maximum = FileContentReader.maximumLineLength
        guard case .text = try FileContentReader.decode(Data(String(repeating: "😀", count: maximum / 2).utf8), plain: false) else {
            Issue.record("Line at the limit was rejected")
            return
        }
        guard case .unavailable(.lineTooLong) = try FileContentReader.decode(
            Data(String(repeating: "😀", count: maximum / 2 + 1).utf8), plain: false) else {
            Issue.record("Long UTF-16 line was accepted")
            return
        }
        for newline in ["\r\n", "\n", "\r", "\u{2028}", "\u{2029}"] {
            let source = String(repeating: newline, count: FileContentReader.maximumLines - 1)
            guard case .text = try FileContentReader.decode(Data(source.utf8), plain: false) else {
                Issue.record("Line count at the limit was rejected")
                return
            }
            guard case .unavailable(.tooManyLines) = try FileContentReader.decode(Data((source + newline).utf8), plain: false) else {
                Issue.record("Too many lines were accepted")
                return
            }
        }
    }

    @Test func byteLimitsRequireExplicitLoadingAndNeverTruncate() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        for size in [FileContentReader.automaticLimit - 1, FileContentReader.automaticLimit,
                     FileContentReader.automaticLimit + 1, FileContentReader.maximumBytes,
                     FileContentReader.maximumBytes + 1] {
            // Short lines keep this fixture within the independent line limits, including at 10 MiB.
            var data = Data(repeating: 65, count: size)
            for offset in stride(from: 127, to: size, by: 128) { data[offset] = 10 }
            try data.write(to: url)
            let automatic = try FileContentReader.read(url, allowLarge: false)
            #expect(automatic.metadata.size == size)
            if size <= FileContentReader.automaticLimit {
                guard case .text(let text, let plain, _) = automatic.content else {
                    Issue.record("Small file was not automatically loaded")
                    return
                }
                #expect(Data(text.utf8) == data)
                #expect(!plain)
            } else if size <= FileContentReader.maximumBytes {
                guard case .requiresLoad = automatic.content else {
                    Issue.record("Large file was automatically loaded")
                    return
                }
                let manual = try FileContentReader.read(url, allowLarge: true)
                guard case .text(let text, let plain, _) = manual.content else {
                    Issue.record("Explicit loading failed")
                    return
                }
                #expect(plain)
                #expect(Data(text.utf8) == data)
            } else {
                guard case .unavailable(.tooLarge) = automatic.content else {
                    Issue.record("Oversized file was not rejected")
                    return
                }
            }
        }
    }

    @Test func specialFilesAndSymbolicLinksAreNotRead() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        guard case .unavailable(.notRegular) = try FileContentReader.read(url, allowLarge: true).content else {
            Issue.record("Symbolic link was followed")
            return
        }
        try FileManager.default.removeItem(at: url)
        #expect(mkfifo(url.path, 0o600) == 0)
        guard case .unavailable(.notRegular) = try FileContentReader.read(url, allowLarge: true).content else {
            Issue.record("FIFO was opened")
            return
        }
    }

    @Test func cancelledReadsAndTokenizationStop() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try FileContentReader.read(temporaryURL(), allowLarge: true)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let highlighting = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await FileSyntaxHighlighter.shared.spans(in: "let value = 1", path: "test.swift")
        }
        await #expect(throws: CancellationError.self) { try await highlighting.value }
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("foldgit-content-\(UUID())")
    }
}
