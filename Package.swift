// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ivy",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "Ivy", targets: ["Ivy"]),
    ],
    dependencies: [
        .package(url: "https://github.com/treehauslabs/Acorn.git", branch: "master"),
        .package(url: "https://github.com/treehauslabs/Tally.git", branch: "main"),
    ],
    targets: [
        .target(name: "Ivy", dependencies: ["Acorn", "Tally"]),
        .testTarget(name: "IvyTests", dependencies: ["Ivy"]),
    ]
)
