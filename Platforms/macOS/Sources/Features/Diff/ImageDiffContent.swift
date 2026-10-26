import AppKit
import FoldGitCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ImageDiffContext: Hashable, Sendable {
    var old: GitFileVersion
    var new: GitFileVersion

    static let unstaged = Self(old: .index, new: .workingTree)
    static let staged = Self(old: .revision("HEAD"), new: .index)

    func version(for file: FileDiff, oldSide: Bool) -> GitFileVersion {
        if file.extendedHeaderLines.contains(where: { $0.hasPrefix(oldSide ? "new file mode " : "deleted file mode ") }) {
            return .absent
        }
        let version = oldSide ? old : new
        // Blob IDs also cover untracked files included in a stash's third parent.
        if case .revision = version,
           let line = file.extendedHeaderLines.first(where: { $0.hasPrefix("index ") }),
           let pair = line.split(separator: " ").dropFirst().first {
            let objects = pair.components(separatedBy: "..")
            if objects.count == 2 {
                let object = objects[oldSide ? 0 : 1]
                if !object.isEmpty, object.allSatisfy({ $0.isHexDigit }) {
                    return object.allSatisfy({ $0 == "0" }) ? .absent : .blob(object)
                }
            }
        }
        return version
    }
}

extension EnvironmentValues {
    @Entry var imageDiffContext: ImageDiffContext?
    @Entry var imageDiffRefreshID = 0
}

/// CGImage is immutable and can safely cross the decoding task boundary.
struct DiffImage: @unchecked Sendable {
    let image: CGImage
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int
    let format: String

    private static let supportedTypes = Set(CGImageSourceCopyTypeIdentifiers() as! [String])

    static func supports(path: String) -> Bool {
        guard let type = UTType(filenameExtension: (path as NSString).pathExtension) else { return false }
        return supportedTypes.contains(type.identifier)
    }

    static func decode(_ data: Data) throws -> Self {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw GitExecutionError(description: String(localized: "The image could not be decoded."))
        }
        guard Double(width) * Double(height) <= 40_000_000 else {
            throw GitExecutionError(description: String(localized: "The image is too large to preview."))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw GitExecutionError(description: String(localized: "The image could not be decoded."))
        }
        let orientation = properties[kCGImagePropertyOrientation] as? Int
        let swapsDimensions = orientation.map { (5...8).contains($0) } == true
        let type = UTType(identifier as String)
        return Self(image: image, pixelWidth: swapsDimensions ? height : width,
                    pixelHeight: swapsDimensions ? width : height, byteCount: data.count,
                    format: type?.preferredFilenameExtension?.uppercased() ?? (identifier as String))
    }
}

enum DiffImageState {
    case loading
    case absent
    case loaded(DiffImage)
    case failed(String)

    static func load(directory: URL, path: String, version: GitFileVersion) async -> Self {
        do {
            guard let data = try await GitFileContent.read(at: directory, path: path, version: version) else { return .absent }
            let image = try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try DiffImage.decode(data)
            }.value
            try Task.checkCancellation()
            return .loaded(image)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

struct ImageDiffZoom {
    static func scale(pixelSize: CGSize, viewport: CGSize, displayScale: CGFloat, zoom: CGFloat?) -> CGFloat {
        if let zoom { return zoom / displayScale }
        return max(0.001, min(1 / displayScale,
                             min(max(1, viewport.width - 32) / pixelSize.width,
                                 max(1, viewport.height - 32) / pixelSize.height)))
    }
}
