import AppKit

/// File icons use their own associations, independently of syntax highlighting.
struct FileIconTheme: Decodable, Sendable {
    let defaultIcon: String
    /// Icons with a separate drawing for light appearances, stored as `<icon>.light.svg`.
    let lightIcons: Set<String>
    let fileNames: [String: String]
    let fileExtensions: [String: String]

    static let bundled: FileIconTheme = {
        guard let url = Bundle.main.url(forResource: "MaterialFileIcons", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let theme = try? JSONDecoder().decode(FileIconTheme.self, from: data) else {
            preconditionFailure("The bundled Material Icon Theme associations are missing or invalid.")
        }
        return theme
    }()

    func iconName(filePath: String) -> String {
        let components = filePath.split(separator: "/").map { $0.lowercased() }

        // Some upstream rules include parent directories, such as .github/FUNDING.yml.
        // Try the longest path first, without matching partial directory names.
        for index in components.indices {
            let candidate = components[index...].joined(separator: "/")
            if let icon = fileNames[candidate] {
                return icon
            }
        }

        guard let filename = components.last else { return defaultIcon }
        // Removing one component at a time preserves compound suffix priority.
        // Also allow a leading dot, for example .env.production.
        for dot in filename.indices where filename[dot] == "." {
            let suffix = String(filename[filename.index(after: dot)...])
            if let icon = fileExtensions[suffix] {
                return icon
            }
        }
        return defaultIcon
    }

    /// SVG files are drawn by AppKit on demand; an asset catalog would also store two raster copies of each.
    @MainActor
    func image(filePath: String, isDark: Bool) -> NSImage {
        let icon = iconName(filePath: filePath)
        let file = !isDark && lightIcons.contains(icon) ? icon + ".light" : icon
        return Self.image(file: file) ?? Self.image(file: defaultIcon) ?? NSImage()
    }

    @MainActor private static var images: [String: NSImage] = [:]

    @MainActor
    static func image(file: String) -> NSImage? {
        if let image = images[file] { return image }
        guard let url = Bundle.main.url(forResource: file, withExtension: "svg", subdirectory: "MaterialFileIcons"),
              let image = NSImage(contentsOf: url) else { return nil }
        images[file] = image
        return image
    }
}
