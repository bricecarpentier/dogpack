// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Dogpack",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "julius", targets: ["julius"]),
        .library(name: "zoomies", targets: ["zoomies"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.1"),
    ],
    targets: [
        .target(name: "julius"),
        .target(name: "zoomies", dependencies: ["julius"]),
        .executableTarget(name: "dogpack", dependencies: [
            "zoomies",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .testTarget(name: "dogpackTests", dependencies: ["dogpack"]),
        .testTarget(name: "juliusTests", dependencies: ["julius"]),
        .testTarget(name: "zoomiesTests", dependencies: ["zoomies"]),
        .plugin(
            name: "FormatSwift",
            capability: .command(
                intent: .sourceCodeFormatting(),
                permissions: [
                    .writeToPackageDirectory(reason: "Needed to format source files in place"),
                ]
            )
        ),
        .plugin(
            name: "LintSwift",
            capability: .command(
                intent: .custom(verb: "lint", description: "Lint Swift source files"),
                permissions: []
            )
        ),
    ]
)
