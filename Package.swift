// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FoldGit",
    // Apple deployment minimums do not exclude Windows from this package.
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FoldGitCore", targets: ["FoldGitCore"]),
        .library(name: "FoldGitTestSupport", targets: ["FoldGitTestSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "1.0.0"),
    ],
    targets: [
        .target(name: "FoldGitCore", dependencies: [
            .product(name: "Subprocess", package: "swift-subprocess"),
        ], path: "Shared/Sources/FoldGitCore"),
        .target(name: "FoldGitTestSupport", dependencies: ["FoldGitCore"], path: "Shared/Testing"),
        .testTarget(name: "FoldGitCoreTests", dependencies: ["FoldGitCore", "FoldGitTestSupport"], path: "Shared/Tests/FoldGitCoreTests"),
    ],
    swiftLanguageModes: [.v6]
)
