import Foundation
@testable import julius
import Testing

// MARK: - Helpers

/// A mock that returns canned `ProviderEvent` streams in sequence, one per `send()` call.
private final class SequencedMockProvider: Provider, @unchecked Sendable {
    private let cannedEventSequences: [[ProviderEvent]]
    private(set) var callCount = 0

    init(cannedEventSequences: [[ProviderEvent]]) {
        self.cannedEventSequences = cannedEventSequences
    }

    func send(_: ProviderRequest) async throws -> ResponseStream {
        let events = cannedEventSequences[callCount]
        callCount += 1

        let (stream, continuation) = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
        Task {
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
        return ResponseStream(events: stream, cancel: {})
    }
}

/// Provider that returns a single canned `ResponseStream` every time.
private final class HangingProvider: Provider, @unchecked Sendable {
    private let responseStream: ResponseStream

    init(responseStream: ResponseStream) {
        self.responseStream = responseStream
    }

    func send(_: ProviderRequest) async throws -> ResponseStream {
        responseStream
    }
}

/// Consume a `LoopEvent` stream and return the `AssistantMessage` from `.complete`.
private func collectMessage(
    _ stream: AsyncThrowingStream<LoopEvent, Error>,
) async throws -> AssistantMessage {
    for try await event in stream {
        if case let .complete(message) = event { return message }
    }
    throw JuliusError.cancelled
}

// MARK: - Tests

@Suite("Loop integration tests")
struct LoopTests {
    /// Single-turn: provider returns `.stop` immediately. Loop exits after one iteration.
    @Test
    func `single turn returns immediately`() async throws {
        let session = InMemorySession()
        try await session.append(.user("Hello"))

        let provider = SequencedMockProvider(cannedEventSequences: [
            [
                .textDelta("Hi there"),
                .done(.stop),
            ],
        ])

        let loop = Loop(
            provider: provider,
            session: session,
            model: "gpt-4o",
            maxTokens: 256,
        )

        let result = try await collectMessage(loop.run())

        #expect(result.stopReason == .stop)
        #expect(result.content == [.text("Hi there")])
        #expect(provider.callCount == 1)

        let messages = await session.messages()
        #expect(messages.count == 2) // user + assistant
    }

    /// Multi-turn: first response returns `.length`, second returns `.stop`.
    /// Loop iterates twice, session accumulates both assistant messages.
    @Test
    func `multi turn loops until stop`() async throws {
        let session = InMemorySession()
        try await session.append(.user("Explain recursion"))

        let provider = SequencedMockProvider(cannedEventSequences: [
            [
                .textDelta("Recursion is"),
                .done(.length),
            ],
            [
                .textDelta(" when a function calls itself."),
                .done(.stop),
            ],
        ])

        let loop = Loop(
            provider: provider,
            session: session,
            model: "gpt-4o",
            maxTokens: 256,
        )

        let result = try await collectMessage(loop.run())

        #expect(result.stopReason == .stop)
        #expect(result.content == [.text(" when a function calls itself.")])
        #expect(provider.callCount == 2)

        let messages = await session.messages()
        // user + assistant(length) + assistant(stop)
        #expect(messages.count == 3)
    }

    /// Task cancellation ends the stream without hanging.
    @Test
    func `task cancellation ends stream`() async {
        let session = InMemorySession()
        try? await session.append(.user("Hello"))

        // Provider that blocks until cancelled — stream finishes on cancel.
        let (stream, continuation) = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
        let hangingProvider = HangingProvider(responseStream: ResponseStream(
            events: stream,
            cancel: { continuation.finish() },
        ))

        let loop = Loop(
            provider: hangingProvider,
            session: session,
            model: "gpt-4o",
            maxTokens: 256,
        )

        let task = Task {
            for try await _ in loop.run() {}
        }

        // Give the loop time to enter the stream consumption, then cancel.
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        // Stream should end promptly — the consumer sees nil (normal end)
        // because AsyncThrowingStream.Iterator.next() returns nil on cancellation.
        // The child task is cancelled via onTermination (fired on iterator deinit).
        _ = try? await task.value
    }

    /// Stop condition that returns true after one message halts with JuliusError.cancelled.
    @Test
    func `stop condition halts loop`() async throws {
        let session = InMemorySession()
        try await session.append(.user("Hello"))

        let provider = SequencedMockProvider(cannedEventSequences: [
            [
                .textDelta("Hi"),
                .done(.length),
            ],
            // Second response should never be reached
            [
                .textDelta(" there"),
                .done(.stop),
            ],
        ])

        let loop = Loop(
            provider: provider,
            session: session,
            model: "gpt-4o",
            maxTokens: 256,
            stopCondition: { session in
                await session.messages().count >= 2 // user + first assistant
            },
        )

        do {
            _ = try await collectMessage(loop.run())
            Issue.record("Expected JuliusError.cancelled")
        } catch let error as JuliusError {
            if case .cancelled = error {
                // Correct
            } else {
                Issue.record("Wrong JuliusError case: \(error)")
            }
        }
    }

    /// Streaming deltas arrive in order before `.complete`.
    @Test
    func `streaming deltas observed`() async throws {
        let session = InMemorySession()
        try await session.append(.user("Hello"))

        let provider = SequencedMockProvider(cannedEventSequences: [
            [
                .reasoningDelta("thinking"),
                .textDelta("hello"),
                .done(.stop),
            ],
        ])

        let loop = Loop(
            provider: provider,
            session: session,
            model: "gpt-4o",
            maxTokens: 256,
        )

        var events: [LoopEvent] = []
        for try await event in loop.run() {
            events.append(event)
        }

        // 3 deltas + 1 complete
        #expect(events.count == 4)
        #expect(events[0] == .delta(.reasoningDelta("thinking")))
        #expect(events[1] == .delta(.textDelta("hello")))
        #expect(events[2] == .delta(.done(.stop)))

        if case let .complete(message) = events[3] {
            #expect(message.stopReason == .stop)
            #expect(message.content == [.reasoning("thinking"), .text("hello")])
        } else {
            Issue.record("Expected .complete as last event, got \(events[3])")
        }
    }
}

// MARK: - Tool Loop Tests

@Suite("Loop tool tests")
struct LoopToolTests {
    private let weatherTool = ToolDefinition(
        name: "get_weather",
        description: "Get weather",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "city": .object(["type": .string("string")]),
            ]),
        ]),
    )

    /// Loop with tools: provider returns toolUse -> loop yields .toolCalls then .complete.
    @Test
    func `tool use yields tool calls then complete`() async throws {
        let session = InMemorySession()
        try await session.append(.user("What's the weather?"))

        let provider = SequencedMockProvider(cannedEventSequences: [
            [
                .toolCall(ToolCall(id: "call_1", name: "get_weather", arguments: "{\"city\": \"Paris\"}")),
                .done(.toolUse),
            ],
        ])

        let loop = Loop(
            provider: provider,
            session: session,
            model: "gpt-4o",
            maxTokens: 256,
            tools: [weatherTool],
        )

        var events: [LoopEvent] = []
        for try await event in loop.run() {
            events.append(event)
        }

        // .delta(.toolCall) + .delta(.done(.toolUse)) + .toolCalls + .complete
        #expect(events.count == 4)

        let expectedCall = ToolCall(id: "call_1", name: "get_weather", arguments: "{\"city\": \"Paris\"}")
        #expect(events[0] == .delta(.toolCall(expectedCall)))
        #expect(events[1] == .delta(.done(.toolUse)))

        if case let .toolCalls(calls) = events[2] {
            #expect(calls.count == 1)
            #expect(calls[0] == expectedCall)
        } else {
            Issue.record("Expected .toolCalls at index 2, got \(events[2])")
        }

        if case let .complete(message) = events[3] {
            #expect(message.stopReason == .toolUse)
            if case let .toolUse(call) = message.content[0] {
                #expect(call.id == "call_1")
            } else {
                Issue.record("Expected .toolUse content block")
            }
        } else {
            Issue.record("Expected .complete at index 3, got \(events[3])")
        }

        let messages = await session.messages()
        #expect(messages.count == 2)
    }

    /// Loop with tools, provider returns stop immediately -> normal stream (no regressions).
    @Test
    func `tool enabled but stop returned`() async throws {
        let session = InMemorySession()
        try await session.append(.user("Hello"))

        let provider = SequencedMockProvider(cannedEventSequences: [
            [
                .textDelta("Hi there"),
                .done(.stop),
            ],
        ])

        let loop = Loop(
            provider: provider,
            session: session,
            model: "gpt-4o",
            maxTokens: 256,
            tools: [weatherTool],
        )

        let result = try await collectMessage(loop.run())

        #expect(result.stopReason == .stop)
        #expect(result.content == [.text("Hi there")])
        #expect(provider.callCount == 1)
    }

    /// Tool call events appear as .delta(.toolCall) during streaming.
    @Test
    func `tool call delta events during streaming`() async throws {
        let session = InMemorySession()
        try await session.append(.user("Weather?"))

        let provider = SequencedMockProvider(cannedEventSequences: [
            [
                .textDelta("Let me check."),
                .toolCall(ToolCall(id: "call_2", name: "get_weather", arguments: "{}")),
                .done(.toolUse),
            ],
        ])

        let loop = Loop(
            provider: provider,
            session: session,
            model: "gpt-4o",
            maxTokens: 256,
        )

        var events: [LoopEvent] = []
        for try await event in loop.run() {
            events.append(event)
        }

        // .delta(.textDelta) + .delta(.toolCall) + .delta(.done) + .toolCalls + .complete
        #expect(events.count == 5)
        #expect(events[0] == .delta(.textDelta("Let me check.")))
        let call2 = ToolCall(id: "call_2", name: "get_weather", arguments: "{}")
        #expect(events[1] == .delta(.toolCall(call2)))
        #expect(events[2] == .delta(.done(.toolUse)))

        if case let .complete(message) = events[4] {
            #expect(message.content.count == 2)
            #expect(message.content[0] == .text("Let me check."))
            if case let .toolUse(call) = message.content[1] {
                #expect(call.id == "call_2")
            } else {
                Issue.record("Expected .toolUse at content[1]")
            }
        } else {
            Issue.record("Expected .complete as last event")
        }
    }
}
