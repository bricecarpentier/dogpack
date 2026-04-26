// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Dogpack",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "julius", targets: ["julius"]),
    ],
    targets: [
        .target(name: "julius"),
        .executableTarget(name: "dogpack", dependencies: ["julius"]),
        .testTarget(name: "dogpackTests", dependencies: ["dogpack"]),
        .testTarget(name: "juliusTests", dependencies: ["julius"]),
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
