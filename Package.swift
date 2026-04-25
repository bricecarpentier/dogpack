// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Dogpack",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "dogpack"),
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
