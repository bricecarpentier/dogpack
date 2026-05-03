import Foundation
@testable import julius
import Testing

// MARK: - SSE Chunk Helpers

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
        "id": "chatcmpl-test",
        "object": "chat.completion.chunk",
        "model": "gpt-4o",
        "choices": [choice],
    ]
    // swiftlint:disable:next force_try
    return try! JSONSerialization.data(withJSONObject: payload)
}

@Suite("OpenAIProvider integration tests")
struct OpenAIProviderTests {
    /// Full streaming turn: build ProviderRequest, use MockTransport with
    /// canned multi-event SSE JSON, consume all ProviderEvents, verify
    /// sequence (reasoningDelta, textDelta, textDelta, done(.stop)).
    /// Exercises request serialization → transport → SSE parsing → event mapping.
    @Test
    func `full streaming turn`() async throws {
        let transport = MockTransport(cannedChunks: [
            chatChunk(reasoningContent: "User asks basic math"),
            chatChunk(content: "The answer "),
            chatChunk(content: "is 4."),
            chatChunk(finishReason: "stop"),
        ])

        let provider = try OpenAIProvider(
            baseURL: #require(URL(string: "https://api.openai.com/v1")),
            makeTransport: { _, _ in transport },
        )
        let request = ProviderRequest(
            model: "gpt-4o",
            system: "You are helpful.",
            messages: [.user("What is 2+2?")],
            maxTokens: 1024,
        )

        let responseStream = try await provider.send(request)

        var events: [ProviderEvent] = []
        for try await event in responseStream.events {
            events.append(event)
        }

        #expect(events.count == 4)
        #expect(events[0] == .reasoningDelta("User asks basic math"))
        #expect(events[1] == .textDelta("The answer "))
        #expect(events[2] == .textDelta("is 4."))
        #expect(events[3] == .done(.stop))

        // Cancel is callable
        await responseStream.cancel()
    }

    /// Request JSON shape verification: capture the Data passed to
    /// MockTransport.send(), parse it back as JSON, verify correct fields.
    @Test
    func `request json shape`() async throws {
        let transport = MockTransport(cannedChunks: [
            chatChunk(content: "hi"),
            chatChunk(finishReason: "stop"),
        ])

        let provider = try OpenAIProvider(
            baseURL: #require(URL(string: "https://api.openai.com/v1")),
            makeTransport: { _, _ in transport },
        )
        let request = ProviderRequest(
            model: "gpt-4o-mini",
            system: "Be concise.",
            messages: [
                .user("hello"),
                .assistant(AssistantMessage(content: [.text("hi there")], stopReason: .stop)),
                .user("how are you?"),
            ],
            maxTokens: 512,
            temperature: 0.7,
        )

        _ = try await provider.send(request)

        let sentData = try #require(transport.lastSentData)
        let json = try JSONSerialization.jsonObject(with: sentData)
        guard let body = json as? [String: Any] else {
            Issue.record("Expected JSON object"); return
        }

        #expect(body["model"] as? String == "gpt-4o-mini")
        #expect(body["max_tokens"] as? Int == 512)
        #expect(body["temperature"] as? Double == 0.7)
        #expect(body["stream"] as? Bool == true)
        #expect(body["system"] as? String == "Be concise.")

        guard let messages = body["messages"] as? [[String: Any]] else {
            Issue.record("Expected messages array"); return
        }
        #expect(messages.count == 3)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == "hello")
        #expect(messages[1]["role"] as? String == "assistant")
        #expect(messages[2]["role"] as? String == "user")
    }

    /// Malformed response data surfaces as JuliusError.responseParsingFailed.
    @Test
    func `malformed response surfaces parsing error`() async throws {
        let garbage = Data("this is not valid json".utf8)
        let transport = MockTransport(cannedData: garbage)

        let provider = try OpenAIProvider(
            baseURL: #require(URL(string: "https://api.openai.com/v1")),
            makeTransport: { _, _ in transport },
        )
        let request = ProviderRequest(
            model: "gpt-4o",
            system: "system",
            messages: [.user("test")],
            maxTokens: 100,
        )

        do {
            let responseStream = try await provider.send(request)
            for try await _ in responseStream.events {}
            Issue.record("Expected responseParsingFailed error")
        } catch let error as JuliusError {
            if case .responseParsingFailed = error {
                // Correct
            } else {
                Issue.record("Wrong JuliusError case: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    /// Provider constructs correct full URL (base + endpoint) and passes it to the factory.
    @Test
    func `url construction`() async throws {
        let captured = Box<URL>()
        let transport = MockTransport(
            cannedChunks: [chatChunk(finishReason: "stop")],
        ) { _ in }

        let provider = try OpenAIProvider(
            baseURL: #require(URL(string: "https://api.openai.com/v1")),
            makeTransport: { url, _ in
                captured.value = url
                return transport
            },
        )

        _ = try await provider.send(ProviderRequest(
            model: "gpt-4o",
            system: "system",
            messages: [.user("hi")],
            maxTokens: 10,
        ))

        let url = try #require(captured.value)
        #expect(url.absoluteString == "https://api.openai.com/v1/chat/completions")
    }

    /// API key is forwarded to the transport factory.
    @Test
    func `api key forwarded to factory`() async throws {
        let captured = Box<String?>()
        let transport = MockTransport(
            cannedChunks: [chatChunk(finishReason: "stop")],
        ) { _ in }

        let provider = try OpenAIProvider(
            baseURL: #require(URL(string: "https://api.openai.com/v1")),
            apiKey: "sk-test-key-123",
            makeTransport: { _, key in
                captured.value = key
                return transport
            },
        )

        _ = try await provider.send(ProviderRequest(
            model: "gpt-4o",
            system: "system",
            messages: [.user("hi")],
            maxTokens: 10,
        ))

        #expect(captured.value == "sk-test-key-123")
    }

    @Test
    func `usage event from final chunk`() async throws {
        let transport = MockTransport(cannedChunks: [
            chatChunk(content: "Hi"),
            chatChunk(finishReason: "stop"),
            usageChunk(promptTokens: 150, completionTokens: 10),
        ])

        let provider = try OpenAIProvider(
            baseURL: #require(URL(string: "https://api.openai.com/v1")),
            makeTransport: { _, _ in transport },
        )
        let request = ProviderRequest(
            model: "gpt-4o",
            system: "system",
            messages: [.user("Hello")],
            maxTokens: 256,
        )

        let responseStream = try await provider.send(request)
        var events: [ProviderEvent] = []
        for try await event in responseStream.events {
            events.append(event)
        }

        #expect(events.count == 3)
        #expect(events[0] == .textDelta("Hi"))
        #expect(events[1] == .done(.stop))

        if case let .usage(usage) = events[2] {
            #expect(usage.promptTokens == 150)
            #expect(usage.completionTokens == 10)
        } else {
            Issue.record("Expected .usage at index 2, got \(events[2])")
        }
    }

    @Test
    func `compacted summary serialized as system message`() async throws {
        let transport = MockTransport(cannedChunks: [
            chatChunk(content: "Continuing"),
            chatChunk(finishReason: "stop"),
        ])

        let provider = try OpenAIProvider(
            baseURL: #require(URL(string: "https://api.openai.com/v1")),
            makeTransport: { _, _ in transport },
        )
        let request = ProviderRequest(
            model: "gpt-4o",
            system: "system",
            messages: [
                .user("Start"),
                .compactedSummary("Previous work done"),
                .user("Continue"),
            ],
            maxTokens: 256,
        )

        _ = try await provider.send(request)

        let sentData = try #require(transport.lastSentData)
        let json = try JSONSerialization.jsonObject(with: sentData)
        guard let body = json as? [String: Any],
              let serialized = body["messages"] as? [[String: Any]]
        else {
            Issue.record("Expected JSON with messages"); return
        }

        #expect(serialized.count == 3)
        #expect(serialized[0]["role"] as? String == "user")
        #expect(serialized[1]["role"] as? String == "system")
        #expect(serialized[1]["content"] as? String == "Previous work done")
        #expect(serialized[2]["role"] as? String == "user")
    }
}

/// Thread-safe box for capturing values from Sendable closures.
private final class Box<T>: @unchecked Sendable {
    var value: T?
}

private func usageChunk(promptTokens: Int, completionTokens: Int) -> Data {
    let payload: [String: Any] = [
        "id": "chatcmpl-usage",
        "object": "chat.completion.chunk",
        "model": "gpt-4o",
        "choices": [],
        "usage": [
            "prompt_tokens": promptTokens,
            "completion_tokens": completionTokens,
        ],
    ]
    // swiftlint:disable:next force_try
    return try! JSONSerialization.data(withJSONObject: payload)
}
