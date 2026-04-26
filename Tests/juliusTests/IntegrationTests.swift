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

        let provider = OpenAIProvider(transport: transport)
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
}

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
