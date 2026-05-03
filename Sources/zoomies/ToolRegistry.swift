import julius

/// Registers tools and dispatches incoming tool calls to the right implementation.
/// Uses an actor to provide safe concurrency under Swift strict concurrency checking.
public actor ToolRegistry {
    private var tools: [String: any Tool] = [:]

    public init() {}

    /// Register a tool. Its name must be unique.
    public func register(_ tool: any Tool) throws {
        let name = tool.definition.name
        guard tools[name] == nil else {
            throw ToolRegistryError.duplicateTool(name)
        }
        tools[name] = tool
    }

    /// All registered tool definitions (for including in Loop requests).
    /// Returns definitions sorted alphabetically by name for cache-friendly ordering.
    public var definitions: [ToolDefinition] {
        tools.keys.sorted().map { tools[$0]!.definition }
    }

    /// Dispatch a tool call to the registered implementation.
    public func execute(_ call: ToolCall) async throws -> ToolResult {
        guard let tool = tools[call.name] else {
            throw ToolRegistryError.unknownTool(call.name)
        }
        return try await tool.execute(call)
    }
}

// MARK: - Errors

public enum ToolRegistryError: Error, Sendable {
    case duplicateTool(String)
    case unknownTool(String)
}
