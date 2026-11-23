import AppKit
import FoldGitTestSupport
import SwiftUI
import XCTest
@testable import FoldGit

@MainActor
final class MarkdownPreviewTests: XCTestCase {
    func testRepositoryReferencesStayWithinRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: root.deletingLastPathComponent())
        try Data().write(to: root.appendingPathComponent("README EN.md"))
        let location = MarkdownLocation(directory: root, path: "docs/guide.md")
        XCTAssertEqual(location.relativePath("../README%20EN.md#intro"), "README EN.md")
        for target in ["../../secret.md", "../outside/secret.md", "file:///etc/hosts", "https://example.org/x.png", "//example.org/x.png"] {
            XCTAssertNil(location.relativePath(target))
        }
    }

    func testRevisionPreviewReadsCommittedContentAfterWorkingTreeDeletion() async throws {
        let repository = try await TestRepository.create()
        defer { repository.remove() }
        try repository.write("docs/guide.md", "# Committed guide")
        try await repository.commit("Add guide")
        try FileManager.default.removeItem(at: repository.url.appendingPathComponent("docs/guide.md"))
        let view = RevisionDocumentView(directory: repository.url, version: .revision("HEAD"), path: "docs/guide.md")
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 360),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        for _ in 0..<100 {
            if reader(in: host)?.string.contains("Committed guide") == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Historical preview did not display the committed Markdown file")
    }

    func testMermaidStandaloneAndInvalidDiagram() async throws {
        let parts = try await MarkdownDocument.parse("flowchart LR\n A --> B", kind: .mermaid)
        guard case let .code(source, language, _) = parts.first else { return XCTFail("Missing diagram") }
        XCTAssertEqual(language, "mermaid")
        let (_, pdf) = try await MermaidPreview.shared.render(source: source, width: 90, dark: true)
        XCTAssertNotNil(NSImage(data: pdf))
        do {
            _ = try await MermaidPreview.shared.render(source: "invalid diagram", width: 600, dark: false)
            XCTFail("Invalid Mermaid should use the source fallback")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }

    func testFormattedDocumentInFileViewer() async throws {
        for language in ["en", "zh"] {
            for dark in [false, true] {
                try await verifyFilePreview(language: language, dark: dark)
            }
        }
    }

    private func verifyFilePreview(language: String, dark: Bool) async throws {
        let chinese = language == "zh"
        let heading = chinese ? "发布流程" : "Release workflow"
        let source = """
        # \(heading)

        \(chinese ? "从代码审查到发布，每次合并都经过相同的检查。" : "Every change follows the same path from code review to release.")

        ```mermaid
        flowchart LR
          A[\(chinese ? "提交" : "Commit")] --> B[\(chinese ? "审查" : "Review")]
          B --> C[\(chinese ? "测试" : "Test")]
          C --> D[\(chinese ? "发布" : "Release")]
        ```

        ## \(chinese ? "合并前检查" : "Before merging")

        - [x] \(chinese ? "阅读完整文件并审查差异" : "Read the complete file and review the diff")
        - [ ] \(chinese ? "核对示例与文档" : "Check examples against the documentation")

        | \(chinese ? "命令" : "Command") | \(chinese ? "用途" : "Purpose") |
        | --- | --- |
        | `swift test` | \(chinese ? "运行测试" : "Run the test suite") |
        """
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try source.write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let store = FileContentStore()
        store.show(directory: root, path: "README.md")
        await store.readTask?.value
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let view = FileContentView(store: store, path: "README.md", findRequest: nil)
            .environment(\.folder, root)
            .defaultAppStorage(defaults)
            .environment(\.locale, Locale(identifier: chinese ? "zh-Hans" : "en"))
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFront(nil)
        for _ in 0..<100 {
            if reader(in: host)?.string.contains("swift test") == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let text = try XCTUnwrap(reader(in: host))
        XCTAssertTrue(text.string.contains(heading))
        XCTAssertTrue(text.string.contains("☑"))
        let storage = try XCTUnwrap(text.textStorage)
        var diagram: DiagramAttachment?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let attachment = value as? DiagramAttachment { diagram = attachment }
        }
        for _ in 0..<100 {
            text.display()
            if diagram?.diagram != nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertNotNil(diagram?.diagram)
        XCTAssertGreaterThan(text.bounds.width, 300)
    }

    private func reader(in view: NSView) -> MarkdownTextView? {
        if let text = view as? MarkdownTextView { return text }
        for child in view.subviews {
            if let text = reader(in: child) { return text }
        }
        return nil
    }
}
