import julius

/// A tool that the agent can offer to the LLM and execute on its behalf.
public protocol Tool: Sendable {
    /// The tool definition sent to the LLM in the request.
    var definition: ToolDefinition { get }

    /// Execute a tool call and return the result.
    func execute(_ call: ToolCall) async throws -> ToolResult
}
