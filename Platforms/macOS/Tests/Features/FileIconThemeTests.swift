import AppKit
import FoldGitCore
import Testing
@testable import FoldGit

struct FileIconThemeTests {
    @Test(arguments: [
        ("Sources/Example.swift", "swift"),
        ("docs/guide.md", "markdown"),
        ("组件/按钮.vue", "vue"),
        ("src/main.py", "python"),
        ("src/main.rs", "rust"),
        ("src/main.js", "javascript"),
        ("src/main.ts", "typescript"),
        ("src/App.tsx", "react_ts"),
        ("src/App.jsx", "react"),
        ("src/main.c", "c"),
        ("src/main.cpp", "cpp"),
        ("src/main.m", "objective-c"),
        ("src/main.mm", "objective-cpp"),
        ("src/Main.java", "java"),
        ("src/main.go", "go"),
        ("src/main.ml", "ocaml"),
        ("images/photo.png", "image"),
        ("images/logo.svg", "svg"),
        ("docs/manual.pdf", "pdf"),
        ("archives/source.tar.gz", "zip"),
        ("CONFIG/SETTINGS.YAML", "yaml"),
        ("路径 中/文件.SWIFT", "swift"),
    ])
    func fileExtensions(filePath: String, expected: String) {
        #expect(FileIconTheme.bundled.iconName(filePath: filePath) == expected)
    }

    @Test(arguments: [
        ("Dockerfile", "docker"),
        ("project/Makefile", "makefile"),
        ("project/PACKAGE.JSON", "nodejs"),
        ("project/tsconfig.json", "tsconfig"),
        ("project/vite.config.ts", "vite"),
        ("project/README.md", "readme"),
        ("project/LICENSE", "license"),
        ("project/.gitignore", "git"),
        ("project/.env", "tune"),
        ("project/.github/FUNDING.yml", "github-sponsors"),
        ("project/src/bashly.yaml", "bashly"),
        ("project/not-src/bashly.yaml", "yaml"),
        ("project/.config/stylelintrc.json", "stylelint"),
    ])
    func fileNamesTakePriority(filePath: String, expected: String) {
        #expect(FileIconTheme.bundled.iconName(filePath: filePath) == expected)
    }

    @Test(arguments: [
        ("src/types.d.ts", "typescript-def"),
        ("src/types.d.mts", "typescript-def"),
        ("src/main.test.ts", "test-ts"),
        ("src/main.spec.ts", "test-ts"),
        ("schema/example.schema.json", "json_schema"),
    ])
    func compoundExtensionsTakePriority(filePath: String, expected: String) {
        #expect(FileIconTheme.bundled.iconName(filePath: filePath) == expected)
    }

    @Test func longestParentPathTakesPriority() {
        let theme = FileIconTheme(
            defaultIcon: "file",
            lightIcons: [],
            fileNames: ["folder/name.json": "specific", "name.json": "generic"],
            fileExtensions: ["json": "json"]
        )
        #expect(theme.iconName(filePath: "/project/folder/name.json") == "specific")
        #expect(theme.iconName(filePath: "/project/other-folder/name.json") == "generic")
    }

    @Test(arguments: ["", "untitled", "file.unknown-FoldGit-type", "path.with.dots/unknown", "file."])
    func unknownFilesUseTheThemeDefault(filePath: String) {
        #expect(FileIconTheme.bundled.iconName(filePath: filePath) == "file")
    }

    @Test func deletedFilesUseTheirOriginalExtension() throws {
        let diff = try FileDiff(raw: """
        diff --git a/docs/guide.md b/docs/guide.md
        deleted file mode 100644
        --- a/docs/guide.md
        +++ /dev/null
        @@ -1 +0,0 @@
        -Guide
        """)
        #expect(FileIconTheme.bundled.iconName(filePath: diff.toFilePath) == "markdown")
    }

    @Test func renamedFilesUseTheirNewExtension() throws {
        let diff = try FileDiff(raw: """
        diff --git a/source.js b/source.ts
        similarity index 100%
        rename from source.js
        rename to source.ts
        """)
        #expect(FileIconTheme.bundled.iconName(filePath: diff.toFilePath) == "typescript")
    }

    @MainActor
    @Test func allBundledAssociationsHaveRenderableAssets() {
        let theme = FileIconTheme.bundled
        let icons = Set(theme.fileNames.values).union(theme.fileExtensions.values).union([theme.defaultIcon])
        for file in icons.union(theme.lightIcons.map { $0 + ".light" }) {
            let image = FileIconTheme.image(file: file)
            #expect(image != nil, "Missing bundled icon: \(file)")
            #expect(image?.isValid == true, "Invalid bundled icon: \(file)")
        }
        #expect(theme.lightIcons.isSubset(of: icons))
    }

    @MainActor
    @Test func lightAppearanceUsesTheLightDrawing() throws {
        let theme = FileIconTheme.bundled
        #expect(theme.lightIcons.contains("toml"))
        let light = theme.image(filePath: "example.toml", isDark: false)
        let dark = theme.image(filePath: "example.toml", isDark: true)
        #expect(light !== dark)
        #expect(light === FileIconTheme.image(file: "toml.light"))
        #expect(theme.image(filePath: "main.swift", isDark: false) === theme.image(filePath: "main.swift", isDark: true))
        for image in [light, dark] {
            let rendered = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                image.draw(in: rect)
                return true
            }
            #expect(rendered.tiffRepresentation != nil)
        }
    }
}
