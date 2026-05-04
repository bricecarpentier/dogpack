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
        // Vendored tree-sitter core C library (v0.26.8)
        .target(
            name: "CTreeSitter",
            path: "Vendor/CTreeSitter",
            sources: ["src/lib.c"],
            cSettings: [.headerSearchPath("include")]
        ),
        // Vendored tree-sitter-bash grammar C sources (v0.25.1)
        .target(
            name: "CTreeSitterBash",
            dependencies: ["CTreeSitter"],
            path: "Vendor/CTreeSitterBash",
            cSettings: [.headerSearchPath("include")]
        ),
        .target(name: "julius"),
        .target(
            name: "zoomies",
            dependencies: ["julius", "CTreeSitter", "CTreeSitterBash"]
        ),
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
