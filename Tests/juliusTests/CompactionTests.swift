import Foundation
@testable import julius
import Testing

// MARK: - Mock Strategy

/// A strategy with a fixed range that returns a canned summary.
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

// MARK: - Mock Provider for compaction

private final class StubProvider: Provider, @unchecked Sendable {
    private let events: [ProviderEvent]

    init(events: [ProviderEvent]) {
        self.events = events
    }

    func send(_: ProviderRequest) async throws -> ResponseStream {
        let (stream, continuation) = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
        let events = events
        Task {
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
        return ResponseStream(events: stream, cancel: {})
    }
}

// MARK: - Tests

@Suite("Compaction tests")
struct CompactionTests {
    // MARK: - Compactor.compactIfNeeded

    @Test
    func `no compaction when usage below threshold`() async throws {
        let session = InMemorySession()
        try await session.append(.user("Hello"))
        try await session.append(.assistant(AssistantMessage(content: [.text("Hi")], stopReason: .stop)))

        let strategy = FixedCompactionStrategy(range: 0 ..< 0, summary: "summary")
        let compactor = Compactor(strategy: strategy, tokenLimit: 80000)
        let provider = StubProvider(events: [])

        let result = try await compactor.compactIfNeeded(
            session,
            lastUsage: Usage(promptTokens: 10000, completionTokens: 100),
            system: "Be helpful.",
            provider: provider,
            model: "gpt-4o",
        )

        #expect(result == false)
        let messages = await session.messages()
        #expect(messages.count == 2)
    }

    @Test
    func `no compaction when no usage`() async throws {
        let session = InMemorySession()
        try await session.append(.user("Hello"))

        let strategy = FixedCompactionStrategy(range: 0 ..< 0, summary: "summary")
        let compactor = Compactor(strategy: strategy, tokenLimit: 80000)
        let provider = StubProvider(events: [])

        let result = try await compactor.compactIfNeeded(
            session,
            lastUsage: nil,
            system: "system",
            provider: provider,
            model: "gpt-4o",
        )

        #expect(result == false)
    }

    @Test
    func `compaction replaces old messages with summary`() async throws {
        let session = InMemorySession()
        try await session.append(.user("Task"))
        try await session.append(.user("Step 1 details"))
        try await session.append(.assistant(AssistantMessage(content: [.text("Step 1 done")], stopReason: .stop)))
        try await session.append(.user("Continue"))
        try await session.append(.assistant(AssistantMessage(content: [.text("Step 2")], stopReason: .stop)))

        // Compact range 1..<3: .user("Step 1 details") + .assistant("Step 1 done")
        let strategy = FixedCompactionStrategy(range: 1 ..< 3, summary: "Steps 1 completed")
        let compactor = Compactor(strategy: strategy, tokenLimit: 80000)
        let provider = StubProvider(events: [])

        let result = try await compactor.compactIfNeeded(
            session,
            lastUsage: Usage(promptTokens: 85000, completionTokens: 100),
            system: "system",
            provider: provider,
            model: "gpt-4o",
        )

        #expect(result == true)
        let messages = await session.messages()
        // user(Task), compactedSummary, user(Continue), assistant(Step 2)
        #expect(messages.count == 4)

        guard case let .user(text) = messages[0] else {
            Issue.record("Expected user message at 0"); return
        }
        #expect(text == "Task")

        guard case let .compactedSummary(summary) = messages[1] else {
            Issue.record("Expected compactedSummary at 1"); return
        }
        #expect(summary == "Steps 1 completed")

        guard case let .assistant(msg) = messages[3] else {
            Issue.record("Expected assistant at 3"); return
        }
        #expect(msg.content == [.text("Step 2")])
    }

    @Test
    func `compaction enforces single summary`() async throws {
        let session = InMemorySession()
        try await session.append(.user("Task"))
        try await session.append(.compactedSummary("Old summary"))
        try await session.append(.user("Continue"))
        try await session.append(.assistant(AssistantMessage(content: [.text("Working")], stopReason: .stop)))
        try await session.append(.user("Final"))
        try await session.append(.assistant(AssistantMessage(content: [.text("Done")], stopReason: .stop)))

        // Compact range 1..<4: old summary + user(Continue) + assistant(Working)
        // upperBound 4 is .user("Final") — valid boundary
        let strategy = FixedCompactionStrategy(range: 1 ..< 4, summary: "New combined summary")
        let compactor = Compactor(strategy: strategy, tokenLimit: 80000)
        let provider = StubProvider(events: [])

        let result = try await compactor.compactIfNeeded(
            session,
            lastUsage: Usage(promptTokens: 85000, completionTokens: 100),
            system: "system",
            provider: provider,
            model: "gpt-4o",
        )

        #expect(result == true)
        let messages = await session.messages()
        // user(Task), compactedSummary, user(Final), assistant(Done)
        #expect(messages.count == 4)

        let summaryCount = messages.count(where: {
            if case .compactedSummary = $0 { true } else { false }
        })
        #expect(summaryCount == 1)

        guard case let .compactedSummary(summary) = messages[1] else {
            Issue.record("Expected compactedSummary at 1"); return
        }
        #expect(summary == "New combined summary")
    }

    @Test
    func `no compaction with too few messages`() async throws {
        let session = InMemorySession()
        try await session.append(.user("Hello"))

        let strategy = FixedCompactionStrategy(range: 0 ..< 0, summary: "summary")
        let compactor = Compactor(strategy: strategy, tokenLimit: 80000)
        let provider = StubProvider(events: [])

        let result = try await compactor.compactIfNeeded(
            session,
            lastUsage: Usage(promptTokens: 85000, completionTokens: 100),
            system: "system",
            provider: provider,
            model: "gpt-4o",
        )

        #expect(result == false)
    }

    // MARK: - DefaultCompactionStrategy.compactRange

    @Test
    func `default strategy compacts from start`() {
        let messages: [Message] = [
            .user("Start task"),
            .assistant(AssistantMessage(content: [.text("Step 1")], stopReason: .stop)),
            .user("Continue"),
            .assistant(AssistantMessage(content: [.text("Step 2")], stopReason: .stop)),
            .user("Keep going"),
            .assistant(AssistantMessage(content: [.text("Step 3")], stopReason: .stop)),
            .user("Final step"),
            .assistant(AssistantMessage(content: [.text("Done")], stopReason: .stop)),
        ]

        let strategy = DefaultCompactionStrategy(recentTurnsToKeep: 2)
        let range = strategy.compactRange(in: messages)

        // Keeps last 2 turns (indices 4..8), compacts everything before
        #expect(range == 0 ..< 4)
    }

    @Test
    func `default strategy keeps all when few turns`() {
        let messages: [Message] = [
            .user("Q1"),
            .assistant(AssistantMessage(content: [.text("A1")], stopReason: .stop)),
            .user("Q2"),
            .assistant(AssistantMessage(content: [.text("A2")], stopReason: .stop)),
        ]

        let strategy = DefaultCompactionStrategy(recentTurnsToKeep: 4)
        let range = strategy.compactRange(in: messages)

        // All 2 turns fit within keep=4, compactEnd = 0
        #expect(range == 0 ..< 0)
    }

    @Test
    func `default strategy compacts tool exchanges`() {
        let messages: [Message] = [
            .user("Task"),
            .assistant(AssistantMessage(
                content: [.toolUse(ToolCall(id: "c1", name: "tool", arguments: "{}"))],
                stopReason: .toolUse,
            )),
            .toolResult(ToolResult(callId: "c1", output: "result")),
            .user("Step 2"),
            .assistant(AssistantMessage(content: [.text("Working")], stopReason: .stop)),
            .user("Step 3"),
            .assistant(AssistantMessage(content: [.text("Done")], stopReason: .stop)),
        ]

        let strategy = DefaultCompactionStrategy(recentTurnsToKeep: 1)
        let range = strategy.compactRange(in: messages)

        // With keep=1, recentStart=5 (.user "Step 3"), compacts 0..<5
        #expect(range == 0 ..< 5)
        guard case .user = messages[range.upperBound] else {
            Issue.record("Range should end on a .user message boundary")
            return
        }
    }

    // MARK: - Session.replaceMessages

    @Test
    func `in memory session replace messages`() async throws {
        let session = InMemorySession()
        try await session.append(.user("A"))
        try await session.append(.user("B"))
        try await session.append(.user("C"))

        try await session.replaceMessages([.user("X"), .user("Y")])

        let messages = await session.messages()
        #expect(messages.count == 2)
        guard case let .user(text) = messages[0] else {
            Issue.record("Expected user at 0"); return
        }
        #expect(text == "X")
    }
}
