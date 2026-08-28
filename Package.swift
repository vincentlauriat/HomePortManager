// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HomePortManager",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "HomePortKit", targets: ["HomePortKit"]),
        .executable(name: "hpm", targets: ["hpm"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "5.0.0"),
    ],
    targets: [
        .target(name: "HomePortKit", dependencies: ["Yams"]),
        .executableTarget(name: "hpm", dependencies: [
            "HomePortKit",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        // "hpm" too: EventsCmd (Sources/hpm/Commands.swift) is executable-target code with
        // its own decisions (severity/limit validation, the printed table's shape) that
        // deserve the same `swift test` coverage as everything else — not left untested
        // just because it happens to sit in the executable rather than the library.
        .testTarget(name: "HomePortKitTests", dependencies: ["HomePortKit", "hpm"]),
    ]
)
