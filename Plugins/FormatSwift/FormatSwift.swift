import Foundation
import PackagePlugin

@main
struct FormatSwift: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let tool = try findTool("swiftformat")
        let targets = context.package.targets.compactMap { $0 as? SourceModuleTarget }

        let cachePath = context.pluginWorkDirectoryURL.appendingPathComponent("swiftformat.cache").path

        for target in targets {
            print("Formatting \(target.name)...")
            try run(tool, arguments: ["--cache", cachePath, target.directoryURL.path])
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
