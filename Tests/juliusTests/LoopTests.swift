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

// MARK: - Tests

@Suite("Loop integration tests")
struct LoopTests {
    /// Single-turn: provider returns `.stop` immediately. Loop exits after one iteration.
    @Test
    func `single turn returns immediately`() async throws {
        let session = InMemorySession()
        await session.append(.user("Hello"))

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

        let result = try await loop.run()

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
        await session.append(.user("Explain recursion"))

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

        let result = try await loop.run()

        #expect(result.stopReason == .stop)
        #expect(result.content == [.text(" when a function calls itself.")])
        #expect(provider.callCount == 2)

        let messages = await session.messages()
        // user + assistant(length) + assistant(stop)
        #expect(messages.count == 3)
    }

    /// Task cancellation mid-loop throws JuliusError.cancelled.
    @Test
    func `task cancellation throws cancelled`() async {
        let session = InMemorySession()
        await session.append(.user("Hello"))

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
            try await loop.run()
        }

        // Give the loop time to enter the stream consumption, then cancel.
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected JuliusError.cancelled")
        } catch let error as JuliusError {
            if case .cancelled = error {
                // Correct
            } else {
                Issue.record("Wrong JuliusError case: \(error)")
            }
        } catch is CancellationError {
            // Also acceptable — Task.checkCancellation may throw this
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    /// Stop condition that returns true after one message halts with JuliusError.cancelled.
    @Test
    func `stop condition halts loop`() async throws {
        let session = InMemorySession()
        await session.append(.user("Hello"))

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
            _ = try await loop.run()
            Issue.record("Expected JuliusError.cancelled")
        } catch let error as JuliusError {
            if case .cancelled = error {
                // Correct
            } else {
                Issue.record("Wrong JuliusError case: \(error)")
            }
        }
    }
}
