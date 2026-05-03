import Foundation
@testable import julius
import Testing

// MARK: - Helpers

private struct FixedCompactionStrategy: CompactionStrategy {
    var range: Range<Int>
    var summary: String

    func compactRange(in _: [Message]) -> Range<Int> {
        range
    }

    func generateSummary(
        messages _: [Message], system _: String,
        range _: Range<Int>, provider _: Provider,
        model _: String,
    ) async throws -> String {
        summary
    }
}

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

@Suite("Loop compaction tests")
struct LoopCompactionTests {
    /// Loop with compactor: first response returns high usage + `.length`,
    /// compaction runs before second iteration, then second response returns `.stop`.
    @Test
    func `compaction runs between loop iterations`() async throws {
        let session = InMemorySession()
        try await session.append(.user("Task"))
        try await session.append(.user("Step 1"))
        try await session.append(.assistant(AssistantMessage(content: [.text("Done 1")], stopReason: .stop)))
        try await session.append(.user("Step 2"))

        // Range 1..<3 covers user("Step 1") + assistant("Done 1")
        // upperBound 3 is .user("Step 2") — valid boundary
        let strategy = FixedCompactionStrategy(range: 1 ..< 3, summary: "Step 1 completed")
        let compactor = Compactor(strategy: strategy, tokenLimit: 5000)

        let provider = SequencedMockProvider(cannedEventSequences: [
            // First response: high usage + length (triggers re-iteration)
            [
                .textDelta("Continuing"),
                .done(.length),
                .usage(Usage(promptTokens: 9000, completionTokens: 100)),
            ],
            // Second response: stop
            [
                .textDelta(" done"),
                .done(.stop),
            ],
        ])

        let loop = Loop(
            provider: provider,
            session: session,
            model: "gpt-4o",
            system: "system",
            maxTokens: 256,
            compactor: compactor,
        )

        let result = try await collectMessage(loop.run())
        #expect(result.stopReason == .stop)
        #expect(provider.callCount == 2)

        // Compaction should have replaced messages
        let messages = await session.messages()
        // user(Task), compactedSummary, user(Step 2), assistant(Continuing), assistant(done)
        #expect(messages.count == 5)

        guard case let .compactedSummary(summary) = messages[1] else {
            Issue.record("Expected compactedSummary at index 1, got \(messages[1])")
            return
        }
        #expect(summary == "Step 1 completed")
    }
}
