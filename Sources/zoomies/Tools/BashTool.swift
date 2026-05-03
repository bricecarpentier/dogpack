import Foundation
import julius

/// A bash execution tool that validates commands via tree-sitter before execution.
/// Conforms to the `Tool` protocol from zoomies.
public struct BashTool: Tool, Sendable {
    public let definition: ToolDefinition
    private let validator: BashValidator
    private let workingDirectory: String?
    private let timeout: TimeInterval
    private let allowedCommands: Set<String>?

    public init(
        workingDirectory: String? = nil,
        timeout: TimeInterval = 30,
        allowedCommands: Set<String>? = nil,
    ) {
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.allowedCommands = allowedCommands
        validator = BashValidator()
        definition = ToolDefinition(
            name: "bash",
            description: "Execute a bash command. Commands are validated for syntax before execution.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "command": .object([
                        "type": .string("string"),
                        "description": .string("The bash command to execute"),
                    ]),
                ]),
                "required": .array([.string("command")]),
            ]),
        )
    }

    public func execute(_ call: ToolCall) async throws -> ToolResult {
        // Extract command from arguments JSON
        guard let command = extractCommand(from: call.arguments) else {
            return ToolResult(
                callId: call.id,
                output: "Error: missing or invalid 'command' argument",
            )
        }

        // Optional command allowlist check
        if let allowed = allowedCommands {
            let baseCommand = extractBaseCommand(from: command)
            guard allowed.contains(baseCommand) else {
                return ToolResult(
                    callId: call.id,
                    output: "Error: command '\(baseCommand)' is not in the allowed list",
                )
            }
        }

        // Validate via tree-sitter
        let validationResult = validator.validate(command)
        switch validationResult {
        case .valid:
            break
        case let .invalid(errors):
            let errorMessages = errors.map { "\($0.message) (line \($0.line), column \($0.column))" }
            return ToolResult(
                callId: call.id,
                output: "Syntax validation failed:\n" + errorMessages.joined(separator: "\n"),
            )
        }

        // Execute the command
        return await executeCommand(command, callId: call.id)
    }

    // MARK: - Private

    private func extractCommand(from arguments: String) -> String? {
        // Simple JSON extraction for {"command": "..."}
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = json["command"] as? String
        else {
            return nil
        }
        return command
    }

    private func extractBaseCommand(from command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        // Handle pipes and subshells — take the first token of the first segment
        let firstSegment = trimmed.split(separator: "|", maxSplits: 1).first.map(String.init) ?? trimmed
        let tokens = firstSegment.split(separator: " ", maxSplits: 1)
        return tokens.first.map(String.init) ?? trimmed
    }

    private func executeCommand(_ command: String, callId: String) async -> ToolResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()

                process.standardOutput = stdout
                process.standardError = stderr
                process.arguments = ["-c", command]

                if let workingDirectory {
                    process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
                }

                // Use /bin/bash explicitly
                process.executableURL = URL(fileURLWithPath: "/bin/bash")

                let timer = DispatchSource.makeTimerSource()
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler { [weak process] in
                    process?.terminate()
                }
                timer.resume()

                do {
                    try process.run()
                    process.waitUntilExit()
                    timer.cancel()

                    let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

                    let stdoutStr = String(data: stdoutData, encoding: .utf8) ?? ""
                    let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""

                    var output = ""
                    let exitCode = process.terminationStatus

                    if exitCode == 0 {
                        output = stdoutStr
                    } else if process.terminationReason == .uncaughtSignal {
                        output = "Command timed out after \(Int(timeout))s\n\(stderrStr)"
                    } else {
                        if !stdoutStr.isEmpty { output += stdoutStr + "\n" }
                        if !stderrStr.isEmpty { output += "stderr: " + stderrStr }
                        output += "exit code: \(exitCode)"
                    }

                    continuation.resume(returning: ToolResult(callId: callId, output: output))
                } catch {
                    timer.cancel()
                    continuation.resume(returning: ToolResult(
                        callId: callId,
                        output: "Error: \(error.localizedDescription)",
                    ))
                }
            }
        }
    }
}
