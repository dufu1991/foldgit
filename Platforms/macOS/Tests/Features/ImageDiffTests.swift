import AppKit
import FoldGitCore
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FoldGit

struct ImageDiffTests {
    @Test(arguments: [FileContentReader.automaticLimit + 1, FileContentReader.maximumBytes + 1])
    func fileImagesLoadAutomaticallyBeyondTextSizeLimits(byteCount: Int) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("foldgit-image-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        var data = try imageData(width: 120, height: 80)
        data.append(Data(repeating: 0, count: byteCount - data.count))
        try data.write(to: url)
        let snapshot = try FileContentReader.read(url, allowLarge: false)
        guard case .image(let image) = snapshot.content else {
            Issue.record("Images must use the image decoder without the large text loading prompt")
            return
        }
        #expect(image.pixelWidth == 120)
        #expect(image.pixelHeight == 80)
        #expect(image.byteCount == byteCount)
        #expect(snapshot.metadata.size == byteCount)
    }

    @MainActor @Test func fileImageRefreshHandlesReplacementCorruptionAndRemoval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("foldgit-image-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("preview.png")
        try imageData(width: 120, height: 80).write(to: url)
        let store = FileContentStore()
        defer { store.hide() }
        store.show(directory: directory, path: url.lastPathComponent)
        await store.readTask?.value
        guard case .image(let first) = store.state else {
            Issue.record("File content did not load an image")
            return
        }
        #expect(first.pixelWidth == 120)
        try imageData(width: 90, height: 60).write(to: url, options: .atomic)
        store.refresh()
        await store.refreshTask?.value
        await store.readTask?.value
        guard case .image(let changed) = store.state else {
            Issue.record("The changed image was not reloaded")
            return
        }
        #expect(changed.pixelWidth == 90)
        #expect(changed.pixelHeight == 60)

        try Data([0, 255, 1]).write(to: url, options: .atomic)
        store.refresh()
        await store.refreshTask?.value
        await store.readTask?.value
        guard case .failed = store.state else {
            Issue.record("A corrupt image must report an image decoding failure")
            return
        }
        try FileManager.default.removeItem(at: url)
        store.refresh()
        await store.refreshTask?.value
        guard case .missing = store.state else {
            Issue.record("A removed image must show the missing file state")
            return
        }
    }

    @Test func imageByteLimitAndSymbolicLinkRulesMatchThePreviewReader() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("foldgit-image-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("large.png")
        try Data().write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(GitRuntime.outputLimit + 1))
        try handle.close()
        guard case .unavailable(.imageTooLarge) = try FileContentReader.read(url, allowLarge: false).content else {
            Issue.record("Image byte limits must be checked before decoding")
            return
        }
        let link = directory.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        guard case .unavailable(.notRegular) = try FileContentReader.read(link, allowLarge: false).content else {
            Issue.record("Image previews must not bypass the symbolic link restriction")
            return
        }
    }

    @Test func metadataUsesPixelsAndOriginalByteCount() throws {
        let data = try imageData(width: 120, height: 80)
        let image = try DiffImage.decode(data)
        #expect(image.pixelWidth == 120)
        #expect(image.pixelHeight == 80)
        #expect(image.byteCount == data.count)
        #expect(image.format == "PNG")
        #expect(image.image.width == 120)
        #expect(image.image.height == 80)
    }

    @Test func exifOrientationRotatesPreviewAndDimensionsTogether() throws {
        let image = try DiffImage.decode(imageData(width: 120, height: 80, orientation: 6))
        #expect(image.pixelWidth == 80)
        #expect(image.pixelHeight == 120)
        #expect(image.image.width == 80)
        #expect(image.image.height == 120)
    }

    @Test func corruptImagesFailAndTextFilesKeepTheirDiff() {
        #expect(throws: (any Error).self) { try DiffImage.decode(Data([0, 255, 1])) }
        #expect(DiffImage.supports(path: "folder/Image.PNG"))
        #expect(DiffImage.supports(path: "photo.jpeg"))
        #expect(!DiffImage.supports(path: "file.swift"))
        #expect(!DiffImage.supports(path: "vector.svg"))
    }

    @Test func zoomFitsLargeImagesAndAccountsForRetinaPixels() {
        let pixels = CGSize(width: 2400, height: 1200)
        let viewport = CGSize(width: 432, height: 300)
        #expect(ImageDiffZoom.scale(pixelSize: pixels, viewport: viewport, displayScale: 2, zoom: nil) == 1.0 / 6)
        #expect(ImageDiffZoom.scale(pixelSize: pixels, viewport: viewport, displayScale: 2, zoom: 1) == 0.5)
        #expect(ImageDiffZoom.scale(pixelSize: pixels, viewport: viewport, displayScale: 2, zoom: 2) == 1)
        #expect(ImageDiffZoom.scale(pixelSize: CGSize(width: 20, height: 20), viewport: viewport, displayScale: 2, zoom: nil) == 0.5)
    }

    @Test func addedDeletedAndRenamedFilesResolveCorrectVersions() throws {
        let added = try FileDiff(raw: "diff --git a/new.png b/new.png\nnew file mode 100644\nindex 0000000..abcdef0\nBinary files /dev/null and b/new.png differ")
        #expect(ImageDiffContext.staged.version(for: added, oldSide: true) == .absent)
        #expect(ImageDiffContext.staged.version(for: added, oldSide: false) == .index)
        let deleted = try FileDiff(raw: "diff --git a/old.png b/old.png\ndeleted file mode 100644\nindex abcdef0..0000000\nBinary files a/old.png and /dev/null differ")
        #expect(ImageDiffContext.unstaged.version(for: deleted, oldSide: true) == .index)
        #expect(ImageDiffContext.unstaged.version(for: deleted, oldSide: false) == .absent)
        let renamed = try FileDiff(raw: "diff --git a/old.png b/new.png\nsimilarity index 100%\nrename from old.png\nrename to new.png")
        let context = ImageDiffContext(old: .revision("HEAD^"), new: .revision("HEAD"))
        #expect(context.version(for: renamed, oldSide: true) == .revision("HEAD^"))
        #expect(context.version(for: renamed, oldSide: false) == .revision("HEAD"))
        #expect(renamed.fromFilePath == "old.png")
        #expect(renamed.toFilePath == "new.png")
        #expect(context.version(for: added, oldSide: false) == .blob("abcdef0"))
    }

    private func imageData(width: Int, height: Int, orientation: Int = 1) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
