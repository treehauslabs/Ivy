// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ivy",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17), .watchOS(.v10), .visionOS(.v1)],
    products: [
        .library(name: "Ivy", targets: ["Ivy"]),
    ],
    dependencies: [
        .package(url: "https://github.com/treehauslabs/Acorn.git", from: "2.0.0"),
        .package(url: "https://github.com/treehauslabs/Tally.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(
            name: "Ivy",
            dependencies: [
                "Acorn",
                "Tally",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
            ]
        ),
        .testTarget(name: "IvyTests", dependencies: ["Ivy"]),
        .executableTarget(
            name: "IvyBenchmarks",
            dependencies: ["Ivy"],
            path: "Benchmarks/IvyBenchmarks"
        ),
    ]
)
