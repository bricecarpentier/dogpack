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

        // Optional command allowlist check via AST traversal
        if let allowed = allowedCommands {
            let commandNames = await validator.extractCommandNames(command)
            let disallowed = commandNames.filter { !allowed.contains($0) }
            if let blocked = disallowed.first {
                return ToolResult(
                    callId: call.id,
                    output: "Error: command '\(blocked)' is not in the allowed list",
                )
            }
        }

        // Validate via tree-sitter
        let validationResult = await validator.validate(command)
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

    private func executeCommand(_ command: String, callId: String) async -> ToolResult {
        let result = await ProcessRunner.run(
            command,
            workingDirectory: workingDirectory,
            timeout: timeout,
        )
        return ToolResult(callId: callId, output: result.output)
    }
}
