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

enum ContentBlock: Equatable {
    case text(String)
    case reasoning(String)
}

// MARK: - Messages

enum StopReason: Equatable {
    case stop
    case length
    case contentFilter
}

struct AssistantMessage: Equatable {
    var content: [ContentBlock]
    var stopReason: StopReason
}

enum Message: Equatable {
    case user(String)
    case assistant(AssistantMessage)
}

// MARK: - Provider

enum ProviderEvent {
    case reasoningDelta(String)
    case textDelta(String)
    case done(StopReason)
}

struct ProviderRequest: Equatable {
    var model: String
    var system: String?
    var messages: [Message]
    var maxTokens: Int
    var temperature: Double?
}

struct ResponseStream {
    let events: AsyncThrowingStream<ProviderEvent, Error>
    let cancel: @Sendable () async -> Void
}

struct InFlight {
    let events: AsyncThrowingStream<Data, Error>
    let cancel: @Sendable () async -> Void
}

// MARK: - Errors

enum JuliusError: Error {
    case connectionFailed(String)
    case requestSerializationFailed(String)
    case responseParsingFailed(String)
    case transportDisconnected
}
