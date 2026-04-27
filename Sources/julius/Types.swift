import Foundation

// MARK: - JSON

public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Content

public enum ContentBlock: Equatable, Sendable {
    case text(String)
    case reasoning(String)
    case toolUse(ToolCall)
}

// MARK: - Messages

public enum StopReason: Equatable, Sendable {
    case stop
    case length
    case contentFilter
    case toolUse
}

public struct AssistantMessage: Equatable, Sendable {
    public var content: [ContentBlock]
    public var stopReason: StopReason
}

public enum Message: Equatable, Sendable {
    case user(String)
    case assistant(AssistantMessage)
    case toolResult(ToolResult)
}

// MARK: - Tools

public struct ToolCall: Equatable, Sendable {
    public var id: String
    public var name: String
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ToolResult: Equatable, Sendable {
    public var callId: String
    public var output: String

    public init(callId: String, output: String) {
        self.callId = callId
        self.output = output
    }
}

public struct ToolDefinition: Equatable, Sendable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public enum ToolChoice: Equatable, Sendable {
    case auto
    case none
    case required
    case named(String)
}

// MARK: - Provider

public enum ProviderEvent: Equatable, Sendable {
    case reasoningDelta(String)
    case textDelta(String)
    case toolCall(ToolCall)
    case done(StopReason)
}

public struct ProviderRequest: Equatable {
    public var model: String
    public var system: String?
    public var messages: [Message]
    public var maxTokens: Int
    public var temperature: Double?
    public var tools: [ToolDefinition]?
    public var toolChoice: ToolChoice?
}

public enum LoopEvent: Equatable, Sendable {
    case delta(ProviderEvent)
    case complete(AssistantMessage)
    case toolCalls([ToolCall])
}

public struct ResponseStream: Sendable {
    public let events: AsyncThrowingStream<ProviderEvent, Error>
    public let cancel: @Sendable () async -> Void
}

public struct InFlight: Sendable {
    public let events: AsyncThrowingStream<Data, Error>
    public let cancel: @Sendable () async -> Void
}

// MARK: - Errors

public enum JuliusError: Error, Sendable {
    case connectionFailed(String)
    case requestSerializationFailed(String)
    case responseParsingFailed(String)
    case transportDisconnected
    case cancelled
}
