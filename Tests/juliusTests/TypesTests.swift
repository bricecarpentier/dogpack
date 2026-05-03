import Foundation
@testable import julius
import Testing

private actor CancelTracker {
    var wasCancelled = false
    func markCancelled() {
        wasCancelled = true
    }
}

/// Accumulate a ProviderEvent stream into an AssistantMessage.
/// Reusable across tests that simulate provider responses.
private func accumulateMessage(
    from responseStream: ResponseStream,
) async throws -> AssistantMessage {
    var textParts: [String] = []
    var reasoningParts: [String] = []
    var stopReason: StopReason?
    for try await event in responseStream.events {
        switch event {
        case let .reasoningDelta(text):
            reasoningParts.append(text)
        case let .textDelta(text):
            textParts.append(text)
        case let .done(reason):
            stopReason = reason
        case .toolCall:
            break
        case .usage:
            break
        }
    }
    return try AssistantMessage(
        content: reasoningParts.map { .reasoning($0) } + [.text(textParts.joined())],
        stopReason: #require(stopReason),
    )
}

@Suite("Types integration tests")
struct TypesTests {
    /// Simulates a full turn: user message → ProviderRequest → fake ProviderEvent
    /// stream → accumulate into AssistantMessage → append to history → verify.
    @Test
    func `full turn accumulation`() async throws {
        var history: [Message] = [.user("What is 2+2?")]

        let request = ProviderRequest(
            model: "gpt-4o",
            system: "You are a helpful assistant.",
            messages: history,
            maxTokens: 1024,
            temperature: nil,
            tools: [],
        )
        #expect(request.model == "gpt-4o")
        #expect(request.messages.count == 1)

        let (stream, continuation) = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
        let responseStream = ResponseStream(events: stream, cancel: {})
        Task {
            continuation.yield(.reasoningDelta("User asks basic math"))
            continuation.yield(.textDelta("The answer "))
            continuation.yield(.textDelta("is 4."))
            continuation.yield(.done(.stop))
            continuation.finish()
        }

        let assistantMsg = try await accumulateMessage(from: responseStream)

        history.append(.assistant(assistantMsg))
        #expect(history.count == 2)

        if case let .user(text) = history[0] {
            #expect(text == "What is 2+2?")
        } else {
            Issue.record("Expected user message at index 0")
        }

        if case let .assistant(msg) = history[1] {
            #expect(msg.content.count == 2)
            #expect(msg.content[0] == .reasoning("User asks basic math"))
            #expect(msg.content[1] == .text("The answer is 4."))
            #expect(msg.stopReason == .stop)
        } else {
            Issue.record("Expected assistant message at index 1")
        }
    }

    /// Build a ResponseStream, consume partial events, call cancel, verify
    /// stream terminates.
    @Test
    func `streaming with cancellation`() async throws {
        let tracker = CancelTracker()
        let (stream, continuation) = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
        let responseStream = ResponseStream(
            events: stream,
            cancel: { await tracker.markCancelled() },
        )

        Task {
            continuation.yield(.textDelta("Hello"))
            continuation.yield(.textDelta(" world"))
            continuation.finish()
        }

        var collected: [String] = []
        for try await event in responseStream.events {
            if case let .textDelta(text) = event {
                collected.append(text)
            }
            await responseStream.cancel()
        }

        #expect(collected == ["Hello", " world"])
        let wasCancelled = await tracker.wasCancelled
        #expect(wasCancelled)
    }

    /// Construct a JSONValue tree matching a realistic API response and
    /// extract nested values.
    @Test
    func `json value realistic payload`() {
        let payload: JSONValue = .object([
            "id": .string("resp_abc123"),
            "model": .string("gpt-4o"),
            "output": .array([
                .object([
                    "type": .string("reasoning"),
                    "summary": .array([.string("User asks basic math")]),
                ]),
                .object([
                    "type": .string("message"),
                    "content": .array([
                        .object([
                            "type": .string("output_text"),
                            "text": .string("The answer is 4."),
                        ]),
                    ]),
                ]),
            ]),
            "status": .string("completed"),
        ])

        guard case let .object(fields) = payload else {
            Issue.record("Expected object"); return
        }
        #expect(fields["id"] == .string("resp_abc123"))
        #expect(fields["status"] == .string("completed"))

        guard case let .array(output)? = fields["output"], output.count == 2 else {
            Issue.record("Expected output array with 2 items"); return
        }

        if case let .object(reasoningItem) = output[0],
           case let .string(type)? = reasoningItem["type"]
        {
            #expect(type == "reasoning")
        } else {
            Issue.record("Expected reasoning output item")
        }

        if case let .object(messageItem) = output[1],
           case let .array(contentArray)? = messageItem["content"],
           case let .object(textBlock) = contentArray[0],
           case let .string(text)? = textBlock["text"]
        {
            #expect(text == "The answer is 4.")
        } else {
            Issue.record("Expected message output with nested text")
        }
    }

    /// Build an InFlight that throws, verify the error propagates through
    /// iteration.
    @Test
    func `error propagation through stream`() async {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let inFlight = InFlight(events: stream, cancel: {})

        continuation.yield(Data("partial".utf8))
        continuation.finish(throwing: JuliusError.responseParsingFailed("invalid SSE frame"))

        var collected: [Data] = []
        do {
            for try await data in inFlight.events {
                collected.append(data)
            }
            Issue.record("Expected error to be thrown")
        } catch let error as JuliusError {
            if case let .responseParsingFailed(message) = error {
                #expect(message == "invalid SSE frame")
            } else {
                Issue.record("Wrong JuliusError case: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(collected.count == 1)
        #expect(collected[0] == Data("partial".utf8))
    }
}
