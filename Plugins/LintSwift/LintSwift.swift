import Foundation
import PackagePlugin

@main
struct LintSwift: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let tool = try findTool("swiftlint")
        let allTargets: [SourceModuleTarget] = context.package.targets.compactMap { $0 as? SourceModuleTarget }
        let targets = allTargets.filter { target in
            !target.sourceFiles(withSuffix: ".swift").isEmpty
        }

        let cacheDir = context.pluginWorkDirectoryURL.appendingPathComponent("swiftlint.cache").path
        try FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)

        for target in targets {
            print("Linting \(target.name)...")
            try run(tool, arguments: ["lint", "--cache-path", cacheDir, target.directoryURL.path])
        }
    }

    private func findTool(_ name: String) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else {
            struct ToolNotFoundError: Error, CustomStringConvertible {
                let name: String
                var description: String { "'\(name)' not found on PATH" }
            }
            throw ToolNotFoundError(name: name)
        }
        return path
    }

    private func run(_ tool: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            struct ToolFailedError: Error, CustomStringConvertible {
                let tool: String
                var description: String { "'\(tool)' exited with non-zero status" }
            }
            throw ToolFailedError(tool: tool)
        }
    }
}
