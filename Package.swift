// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ord",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Ord", path: "Sources/Ord")
    ]
)
