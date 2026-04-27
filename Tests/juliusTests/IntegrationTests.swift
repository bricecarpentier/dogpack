import Foundation
@testable import julius
import Testing

private func chatChunk(
    index: Int = 0,
    content: String? = nil,
    reasoningContent: String? = nil,
    finishReason: String? = nil,
) -> Data {
    var delta: [String: String] = [:]
    if let content { delta["content"] = content }
    if let reasoningContent { delta["reasoning_content"] = reasoningContent }

    var choice: [String: Any] = [
        "index": index,
        "delta": delta,
    ]
    if let finishReason { choice["finish_reason"] = finishReason }

    let payload: [String: Any] = [
        "id": "chatcmpl-e2e",
        "object": "chat.completion.chunk",
        "model": "gpt-4o",
        "choices": [choice],
    ]
    // swiftlint:disable:next force_try
    return try! JSONSerialization.data(withJSONObject: payload)
}

private func toolCallChunk(
    index: Int = 0,
    callIndex: Int = 0,
    id: String? = nil,
    name: String? = nil,
    arguments: String? = nil,
    finishReason: String? = nil,
) -> Data {
    var tcDelta: [String: Any] = ["index": callIndex]
    if let id { tcDelta["id"] = id }
    tcDelta["type"] = "function"
    var function: [String: String] = [:]
    if let name { function["name"] = name }
    if let arguments { function["arguments"] = arguments }
    if !function.isEmpty { tcDelta["function"] = function }

    var delta: [String: Any] = ["tool_calls": [tcDelta]]

    var choice: [String: Any] = [
        "index": index,
        "delta": delta,
    ]
    if let finishReason { choice["finish_reason"] = finishReason }

    let payload: [String: Any] = [
        "id": "chatcmpl-e2e",
        "object": "chat.completion.chunk",
        "model": "gpt-4o",
        "choices": [choice],
    ]
    // swiftlint:disable:next force_try
    return try! JSONSerialization.data(withJSONObject: payload)
}

// MARK: - Accumulate Helper

/// Accumulate ProviderEvents from a ResponseStream into a single AssistantMessage.
private func accumulate(_ responseStream: ResponseStream) async throws -> AssistantMessage {
    var contentBlocks: [ContentBlock] = []
    var currentText = ""
    var currentReasoning = ""
    var stopReason: StopReason = .stop

    for try await event in responseStream.events {
        switch event {
        case let .textDelta(text):
            currentText += text
        case let .reasoningDelta(text):
            currentReasoning += text
        case let .toolCall(call):
            if !currentReasoning.isEmpty {
                contentBlocks.append(.reasoning(currentReasoning))
                currentReasoning = ""
            }
            if !currentText.isEmpty {
                contentBlocks.append(.text(currentText))
                currentText = ""
            }
            contentBlocks.append(.toolUse(call))
        case let .done(reason):
            if !currentReasoning.isEmpty {
                contentBlocks.append(.reasoning(currentReasoning))
                currentReasoning = ""
            }
            if !currentText.isEmpty {
                contentBlocks.append(.text(currentText))
                currentText = ""
            }
            stopReason = reason
        }
    }

    return AssistantMessage(content: contentBlocks, stopReason: stopReason)
}

// MARK: - Tests

@Suite("End-to-end integration tests")
struct IntegrationTests {
    /// Full user-turn cycle through all layers:
    /// InMemorySession → OpenAIProvider (with MockTransport) → accumulate events → append assistant message.
    @Test
    func `full user turn cycle`() async throws {
        let session = InMemorySession()
        try await session.append(.user("What is 2+2?"))

        let transport = MockTransport(cannedChunks: [
            chatChunk(reasoningContent: "Basic arithmetic"),
            chatChunk(content: "The answer is "),
            chatChunk(content: "4."),
            chatChunk(finishReason: "stop"),
        ])

        let provider = try OpenAIProvider(
            baseURL: #require(URL(string: "https://api.openai.com/v1")),
            makeTransport: { _, _ in transport },
        )
        let history = await session.messages()
        let request = ProviderRequest(
            model: "gpt-4o",
            system: "Be concise.",
            messages: history,
            maxTokens: 256,
        )

        let responseStream = try await provider.send(request)
        let assistantMessage = try await accumulate(responseStream)

        try await session.append(.assistant(assistantMessage))

        let finalHistory = await session.messages()
        #expect(finalHistory.count == 2)

        if case let .user(text) = finalHistory[0] {
            #expect(text == "What is 2+2?")
        } else {
            Issue.record("Expected user message at index 0")
        }

        if case let .assistant(msg) = finalHistory[1] {
            #expect(msg.stopReason == .stop)
            #expect(msg.content.count == 2)
            #expect(msg.content[0] == .reasoning("Basic arithmetic"))
            #expect(msg.content[1] == .text("The answer is 4."))
        } else {
            Issue.record("Expected assistant message at index 1")
        }
    }

    /// Tool call SSE parsing: multi-chunk deltas accumulate into a complete ToolCall,
    /// followed by .done(.toolUse).
    @Test
    func `tool call SSE parsing`() async throws {
        let transport = MockTransport(cannedChunks: [
            toolCallChunk(callIndex: 0, id: "call_abc", name: "get_weather", arguments: "{\"ci"),
            toolCallChunk(callIndex: 0, arguments: "ty\": \"Paris\"}"),
            toolCallChunk(finishReason: "tool_calls"),
        ])

        let provider = try OpenAIProvider(
            baseURL: #require(URL(string: "https://api.openai.com/v1")),
            makeTransport: { _, _ in transport },
        )
        let request = ProviderRequest(
            model: "gpt-4o",
            messages: [.user("What's the weather?")],
            maxTokens: 256,
        )

        let responseStream = try await provider.send(request)
        var events: [ProviderEvent] = []
        for try await event in responseStream.events {
            events.append(event)
        }

        #expect(events.count == 2)

        if case let .toolCall(call) = events[0] {
            #expect(call.id == "call_abc")
            #expect(call.name == "get_weather")
            #expect(call.arguments == "{\"city\": \"Paris\"}")
        } else {
            Issue.record("Expected .toolCall at index 0, got \(events[0])")
        }

        if case let .done(reason) = events[1] {
            #expect(reason == .toolUse)
        } else {
            Issue.record("Expected .done(.toolUse) at index 1, got \(events[1])")
        }
    }

    /// Multiple concurrent tool calls via index field.
    @Test
    func `multiple concurrent tool calls`() async throws {
        let transport = MockTransport(cannedChunks: [
            toolCallChunk(callIndex: 0, id: "call_1", name: "get_weather", arguments: "{\"city"),
            toolCallChunk(callIndex: 1, id: "call_2", name: "get_weather", arguments: "{\"city"),
            toolCallChunk(callIndex: 0, arguments: "\": \"Paris\"}"),
            toolCallChunk(callIndex: 1, arguments: "\": \"London\"}"),
            toolCallChunk(finishReason: "tool_calls"),
        ])

        let provider = try OpenAIProvider(
            baseURL: #require(URL(string: "https://api.openai.com/v1")),
            makeTransport: { _, _ in transport },
        )
        let request = ProviderRequest(
            model: "gpt-4o",
            messages: [.user("Weather for Paris and London")],
            maxTokens: 256,
        )

        let responseStream = try await provider.send(request)
        var events: [ProviderEvent] = []
        for try await event in responseStream.events {
            events.append(event)
        }

        // 2 tool calls + 1 done
        #expect(events.count == 3)

        if case let .toolCall(call0) = events[0] {
            #expect(call0.id == "call_1")
            #expect(call0.name == "get_weather")
            #expect(call0.arguments == "{\"city\": \"Paris\"}")
        } else {
            Issue.record("Expected first .toolCall, got \(events[0])")
        }

        if case let .toolCall(call1) = events[1] {
            #expect(call1.id == "call_2")
            #expect(call1.name == "get_weather")
            #expect(call1.arguments == "{\"city\": \"London\"}")
        } else {
            Issue.record("Expected second .toolCall, got \(events[1])")
        }

        if case let .done(reason) = events[2] {
            #expect(reason == .toolUse)
        } else {
            Issue.record("Expected .done(.toolUse), got \(events[2])")
        }
    }

    /// Full tool cycle step 1: model requests tool use.
    @Test
    func `full tool cycle step 1 model requests tool`() async throws {
        let session = InMemorySession()
        try await session.append(.user("What's the weather in Paris?"))

        let transport = MockTransport(cannedChunks: [
            toolCallChunk(
                callIndex: 0, id: "call_001", name: "get_weather",
                arguments: "{\"city\": \"Paris\"}",
            ),
            toolCallChunk(finishReason: "tool_calls"),
        ])
        let provider = try OpenAIProvider(
            baseURL: #require(URL(string: "https://api.openai.com/v1")),
            makeTransport: { _, _ in transport },
        )

        let weatherTool = ToolDefinition(
            name: "get_weather",
            description: "Get weather",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "city": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("city")]),
            ]),
        )
        let request = await ProviderRequest(
            model: "gpt-4o",
            messages: session.messages(),
            maxTokens: 256,
            tools: [weatherTool],
        )

        let msg = try await accumulate(provider.send(request))
        try await session.append(.assistant(msg))

        #expect(msg.stopReason == .toolUse)
        guard case let .toolUse(call) = msg.content.first else {
            Issue.record("Expected .toolUse content block")
            return
        }
        #expect(call.id == "call_001")
        #expect(call.name == "get_weather")
        #expect(call.arguments == "{\"city\": \"Paris\"}")

        // Verify assistant appended to session
        let messages = await session.messages()
        #expect(messages.count == 2) // user + assistant
    }

    /// Full tool cycle step 2: after receiving tool result, model responds with text.
    @Test
    func `full tool cycle step 2 model responds after tool result`() async throws {
        let session = InMemorySession()
        try await session.append(.user("What's the weather in Paris?"))
        try await session.append(.assistant(AssistantMessage(
            content: [.toolUse(ToolCall(id: "call_001", name: "get_weather", arguments: "{\"city\": \"Paris\"}"))],
            stopReason: .toolUse,
        )))
        try await session.append(.toolResult(ToolResult(callId: "call_001", output: "22°C, sunny")))

        let transport = MockTransport(cannedChunks: [
            chatChunk(content: "It's 22°C and sunny in Paris."),
            chatChunk(finishReason: "stop"),
        ])
        let provider = try OpenAIProvider(
            baseURL: #require(URL(string: "https://api.openai.com/v1")),
            makeTransport: { _, _ in transport },
        )

        let request = await ProviderRequest(
            model: "gpt-4o",
            messages: session.messages(),
            maxTokens: 256,
        )

        let msg = try await accumulate(provider.send(request))
        try await session.append(.assistant(msg))

        #expect(msg.stopReason == .stop)
        #expect(msg.content == [.text("It's 22°C and sunny in Paris.")])

        // Verify full history: user, assistant(toolCall), toolResult, assistant(text)
        let history = await session.messages()
        #expect(history.count == 4)

        guard case let .assistant(toolCallMsg) = history[1] else {
            Issue.record("Expected assistant message at index 1")
            return
        }
        #expect(toolCallMsg.stopReason == .toolUse)

        guard case let .toolResult(toolRes) = history[2] else {
            Issue.record("Expected tool result at index 2")
            return
        }
        #expect(toolRes.callId == "call_001")
        #expect(toolRes.output == "22°C, sunny")

        guard case let .assistant(textMsg) = history[3] else {
            Issue.record("Expected assistant message at index 3")
            return
        }
        #expect(textMsg.stopReason == .stop)
    }
}
