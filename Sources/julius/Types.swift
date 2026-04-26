import Foundation

// MARK: - JSON

indirect enum JSONValue: Equatable {
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
}

// MARK: - Messages

public enum StopReason: Equatable, Sendable {
    case stop
    case length
    case contentFilter
}

public struct AssistantMessage: Equatable, Sendable {
    public var content: [ContentBlock]
    public var stopReason: StopReason
}

public enum Message: Equatable, Sendable {
    case user(String)
    case assistant(AssistantMessage)
}

// MARK: - Provider

public enum ProviderEvent: Equatable, Sendable {
    case reasoningDelta(String)
    case textDelta(String)
    case done(StopReason)
}

public struct ProviderRequest: Equatable {
    public var model: String
    public var system: String?
    public var messages: [Message]
    public var maxTokens: Int
    public var temperature: Double?
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
