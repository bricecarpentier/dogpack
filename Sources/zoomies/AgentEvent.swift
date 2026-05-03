import julius

/// Events emitted by the agent during a turn.
public enum AgentEvent: Equatable, Sendable {
    case textDelta(String)
    case reasoningDelta(String)
    case toolCalls([ToolCall])
    case toolResult(ToolResult)
    case complete(AssistantMessage)
}
