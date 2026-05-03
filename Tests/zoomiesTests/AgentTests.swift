import Foundation
@testable import julius
import Testing
import zoomies

// MARK: - Helpers

/// A mock tool that echoes back the arguments as the result.
struct EchoTool: Tool {
    let definition: ToolDefinition

    init(name: String = "echo") {
        definition = ToolDefinition(
            name: name,
            description: "Echoes back arguments",
            inputSchema: .object(["type": .string("object")]),
        )
    }

    func execute(_ call: ToolCall) async throws -> ToolResult {
        ToolResult(callId: call.id, output: "echo: \(call.arguments)")
    }
}

/// A mock provider that returns canned `ProviderEvent` sequences.
/// Supports multiple `send()` calls — each returns the next sequence.
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

/// Collect all events from an agent turn.
private func collectEvents(
    _ stream: AsyncThrowingStream<AgentEvent, Error>,
) async throws -> [AgentEvent] {
    var events: [AgentEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}

// MARK: - ToolRegistry Tests

@Suite("ToolRegistry tests")
struct ToolRegistryTests {
    /// Registering a tool makes its definition available.
    @Test
    func `register and list definitions`() async throws {
        let registry = ToolRegistry()
        let tool = EchoTool(name: "alpha")
        try await registry.register(tool)

        let defs = await registry.definitions
        #expect(defs.count == 1)
        #expect(defs[0].name == "alpha")
    }

    /// Definitions are returned sorted alphabetically by name.
    @Test
    func `definitions sorted alphabetically`() async throws {
        let registry = ToolRegistry()
        try await registry.register(EchoTool(name: "zeta"))
        try await registry.register(EchoTool(name: "alpha"))
        try await registry.register(EchoTool(name: "mid"))

        let defs = await registry.definitions
        #expect(defs.map(\.name) == ["alpha", "mid", "zeta"])
    }

    /// Dispatching a call routes to the right tool implementation.
    @Test
    func `dispatch executes correct tool`() async throws {
        let registry = ToolRegistry()
        try await registry.register(EchoTool(name: "echo"))

        let call = ToolCall(id: "c1", name: "echo", arguments: "{\"msg\": \"hi\"}")
        let result = try await registry.execute(call)
        #expect(result.callId == "c1")
        #expect(result.output == "echo: {\"msg\": \"hi\"}")
    }
}

// MARK: - Agent Tests

@Suite("Agent integration tests")
struct AgentTests {
    /// Text-only turn: no tools, agent streams deltas and yields complete.
    @Test
    func `text only turn streams events`() async throws {
        let session = InMemorySession()
        let registry = ToolRegistry()

        let provider = SequencedMockProvider(cannedEventSequences: [
            [
                .reasoningDelta("thinking"),
                .textDelta("Hello!"),
                .done(.stop),
            ],
        ])

        let agent = Agent(
            provider: provider,
            session: session,
            registry: registry,
            model: "gpt-4o",
            system: "You are a helpful assistant.",
        )

        let events = try await collectEvents(agent.runTurn("Hi"))

        // .reasoningDelta + .textDelta + .complete
        #expect(events.count == 3)

        #expect(events[0] == .reasoningDelta("thinking"))
        #expect(events[1] == .textDelta("Hello!"))

        if case let .complete(message) = events[2] {
            #expect(message.stopReason == .stop)
            #expect(message.content == [.reasoning("thinking"), .text("Hello!")])
        } else {
            Issue.record("Expected .complete as last event, got \(events[2])")
        }

        // Session should have: user + assistant
        let messages = await session.messages()
        #expect(messages.count == 2)
    }

    /// Tool turn: agent dispatches tool calls, feeds results, gets final response.
    @Test
    func `tool turn executes and feeds back`() async throws {
        let session = InMemorySession()
        let registry = ToolRegistry()
        try await registry.register(EchoTool(name: "echo"))

        let provider = SequencedMockProvider(cannedEventSequences: [
            // First response: model calls tool
            [
                .textDelta("Let me echo."),
                .toolCall(ToolCall(id: "c1", name: "echo", arguments: "{\"msg\": \"hi\"}")),
                .done(.toolUse),
            ],
            // Second response: model responds after tool result
            [
                .textDelta("Done!"),
                .done(.stop),
            ],
        ])

        let agent = Agent(
            provider: provider,
            session: session,
            registry: registry,
            model: "gpt-4o",
            system: "You are a helpful assistant.",
        )

        let events = try await collectEvents(agent.runTurn("echo hi"))

        // First loop: .textDelta + .toolCalls
        // Second loop: .textDelta + .toolResult + .complete
        let textDeltas = events.compactMap { event -> String? in
            if case let .textDelta(text) = event { return text }
            return nil
        }
        #expect(textDeltas == ["Let me echo.", "Done!"])

        let toolCallsEvents = events.compactMap { event -> [ToolCall]? in
            if case let .toolCalls(calls) = event { return calls }
            return nil
        }
        #expect(toolCallsEvents.count == 1)
        #expect(toolCallsEvents[0][0].name == "echo")

        let toolResults = events.compactMap { event -> ToolResult? in
            if case let .toolResult(result) = event { return result }
            return nil
        }
        #expect(toolResults.count == 1)
        #expect(toolResults[0].output == "echo: {\"msg\": \"hi\"}")

        // Final complete
        let completes = events.compactMap { event -> AssistantMessage? in
            if case let .complete(msg) = event { return msg }
            return nil
        }
        #expect(completes.count == 1)
        #expect(completes[0].stopReason == .stop)

        // Session: user + assistant(toolUse) + toolResult + assistant(text)
        let messages = await session.messages()
        #expect(messages.count == 4)
    }

    /// Multiple tool calls in a single response are all executed.
    @Test
    func `multiple tool calls dispatched`() async throws {
        let session = InMemorySession()
        let registry = ToolRegistry()
        try await registry.register(EchoTool(name: "echo"))

        let provider = SequencedMockProvider(cannedEventSequences: [
            [
                .toolCall(ToolCall(id: "c1", name: "echo", arguments: "{\"n\": 1}")),
                .toolCall(ToolCall(id: "c2", name: "echo", arguments: "{\"n\": 2}")),
                .done(.toolUse),
            ],
            [
                .textDelta("All done."),
                .done(.stop),
            ],
        ])

        let agent = Agent(
            provider: provider,
            session: session,
            registry: registry,
            model: "gpt-4o",
            system: "You are a helpful assistant.",
        )

        let events = try await collectEvents(agent.runTurn("echo twice"))

        let toolCallsEvents = events.compactMap { event -> [ToolCall]? in
            if case let .toolCalls(calls) = event { return calls }
            return nil
        }
        #expect(toolCallsEvents.count == 1)
        #expect(toolCallsEvents[0].count == 2)

        let toolResults = events.compactMap { event -> ToolResult? in
            if case let .toolResult(result) = event { return result }
            return nil
        }
        #expect(toolResults.count == 2)
        #expect(toolResults[0].callId == "c1")
        #expect(toolResults[1].callId == "c2")

        // Session: user + assistant(toolUse) + toolResult + toolResult + assistant(text)
        let messages = await session.messages()
        #expect(messages.count == 5)
    }

    /// A failing tool still returns a ToolResult with the error, allowing the LLM to recover.
    @Test
    func `failing tool returns error result`() async throws {
        let session = InMemorySession()
        let registry = ToolRegistry()
        try await registry.register(FailingTool())

        let provider = SequencedMockProvider(cannedEventSequences: [
            [
                .toolCall(ToolCall(id: "c1", name: "fail", arguments: "{}")),
                .done(.toolUse),
            ],
            [
                .textDelta("I see the tool failed."),
                .done(.stop),
            ],
        ])

        let agent = Agent(
            provider: provider,
            session: session,
            registry: registry,
            model: "gpt-4o",
            system: "You are a helpful assistant.",
        )

        let events = try await collectEvents(agent.runTurn("use failing tool"))

        let toolResults = events.compactMap { event -> ToolResult? in
            if case let .toolResult(result) = event { return result }
            return nil
        }
        #expect(toolResults.count == 1)
        #expect(toolResults[0].callId == "c1")
        #expect(toolResults[0].output.contains("someFailure"))

        // Agent continues after error — gets final text response
        let textDeltas = events.compactMap { event -> String? in
            if case let .textDelta(text) = event { return text }
            return nil
        }
        #expect(textDeltas == ["I see the tool failed."])

        // Session: user + assistant(toolUse) + toolResult + assistant(text)
        let messages = await session.messages()
        #expect(messages.count == 4)
    }
}

// MARK: - Failing Tool Helper

/// A tool that always throws, used to test error-capturing behavior.
private struct FailingTool: Tool {
    let definition = ToolDefinition(
        name: "fail",
        description: "Always fails",
        inputSchema: .object(["type": .string("object")]),
    )

    func execute(_: ToolCall) async throws -> ToolResult {
        throw ToolError.someFailure
    }
}

private enum ToolError: Error {
    case someFailure
}
