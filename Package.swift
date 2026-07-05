// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "XFeed",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "XFeed",
            path: "Sources/XFeed",
            resources: [.process("Resources")]
        )
    ]
)
