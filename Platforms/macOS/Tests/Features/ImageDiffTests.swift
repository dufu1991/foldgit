import AppKit
import FoldGitCore
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FoldGit

struct ImageDiffTests {
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
