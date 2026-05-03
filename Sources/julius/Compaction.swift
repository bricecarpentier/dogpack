import Foundation

// MARK: - Compaction Strategy

public protocol CompactionStrategy: Sendable {
    /// Returns the candidate range of messages to compact.
    /// Ranges should start and end on `.user` or `.compactedSummary`
    /// boundaries to preserve tool call/result pairs intact.
    /// The Compactor clamps out-of-bounds ranges but does not
    /// otherwise adjust them.
    func compactRange(in messages: [Message]) -> Range<Int>

    /// Generate a summary of the given messages using the provider.
    /// The default implementation appends a summarization user message
    /// to the conversation and sends it through the provider.
    func generateSummary(
        messages: [Message],
        provider: Provider,
        model: String
    ) async throws -> String
}

// MARK: - Default Strategy

/// A default strategy that keeps the first user message and the last N turns,
/// compacting everything in between into a model-generated summary.
public struct DefaultCompactionStrategy: CompactionStrategy, Sendable {
    /// Number of recent turns to keep intact. A "turn" is a user message
    /// plus the assistant response, including any tool call/result exchanges.
    public var recentTurnsToKeep: Int

    public init(recentTurnsToKeep: Int = 4) {
        self.recentTurnsToKeep = recentTurnsToKeep
    }

    public func compactRange(in messages: [Message]) -> Range<Int> {
        guard messages.count > 1 else {
            return 0 ..< 0
        }

        // Find the start of recent turns by scanning backwards for .user messages
        var turnCount = 0
        var recentStart = messages.count

        for index in stride(from: messages.count - 1, through: 1, by: -1) {
            if case .user = messages[index] {
                turnCount += 1
                recentStart = index
                if turnCount >= recentTurnsToKeep {
                    break
                }
            }
        }

        let compactEnd = min(recentStart, messages.count)

        // Ensure lower bound is on a .user message boundary
        var lower = 1
        while lower < compactEnd {
            if case .user = messages[lower] { break }
            lower += 1
        }

        return lower ..< compactEnd
    }

    public func generateSummary(
        messages: [Message],
        provider: Provider,
        model: String
    ) async throws -> String {
        var summaryMessages = messages
        summaryMessages.append(.user(
            "Summarize the conversation so far, preserving key decisions, findings, and the current state of work.",
        ))

        let request = ProviderRequest(
            model: model,
            system: "You are a helpful assistant that produces concise summaries.",
            messages: summaryMessages,
            maxTokens: 1024,
        )

        let responseStream = try await provider.send(request)

        var summary = ""
        for try await event in responseStream.events {
            if case let .textDelta(text) = event {
                summary += text
            }
        }

        return summary
    }
}

// MARK: - Compactor

public struct Compactor: Sendable {
    public var strategy: CompactionStrategy
    public var tokenLimit: Int

    public init(strategy: CompactionStrategy = DefaultCompactionStrategy(), tokenLimit: Int = 80000) {
        self.strategy = strategy
        self.tokenLimit = tokenLimit
    }

    /// Check if compaction is needed based on the last usage and perform it.
    /// Returns true if compaction was performed.
    public func compactIfNeeded(
        _ session: Session,
        lastUsage: Usage?,
        system: String,
        provider: Provider,
        model: String
    ) async throws -> Bool {
        guard let usage = lastUsage, usage.promptTokens >= tokenLimit else {
            return false
        }

        let messages = await session.messages()
        guard messages.count > 2 else { return false }

        // Phase 1: determine range (pure, no I/O)
        let range = strategy.compactRange(in: messages)
        let clamped = clampRange(range, in: messages)
        guard !clamped.isEmpty else { return false }

        // Phase 2: generate summary (I/O)
        let summary = try await strategy.generateSummary(
            messages: messages,
            provider: provider,
            model: model
        )
        guard !summary.isEmpty else { return false }

        // Phase 3: apply
        let before = messages[0 ..< clamped.lowerBound].filter { !isSummary($0) }
        let after = messages[clamped.upperBound...].filter { !isSummary($0) }

        var newMessages: [Message] = before
        newMessages.append(.compactedSummary(summary))
        newMessages.append(contentsOf: after)

        try await session.replaceMessages(newMessages)
        return true
    }

    // MARK: - Private

    private func clampRange(_ range: Range<Int>, in messages: [Message]) -> Range<Int> {
        let lower = max(range.lowerBound, 0)
        let upper = min(range.upperBound, messages.count)
        let result = lower ..< upper

        assert(
            result.isEmpty || isUserBoundary(result.lowerBound, in: messages),
            "CompactionStrategy returned a range starting on a non-user message at index \(result.lowerBound)"
        )
        assert(
            result.isEmpty || result.upperBound == messages.count || isUserBoundary(result.upperBound, in: messages),
            "CompactionStrategy returned a range ending on a non-user message at index \(result.upperBound)"
        )

        return result
    }

    private func isUserBoundary(_ index: Int, in messages: [Message]) -> Bool {
        switch messages[index] {
        case .user, .compactedSummary: true
        default: false
        }
    }

    private func isSummary(_ message: Message) -> Bool {
        if case .compactedSummary = message { return true }
        return false
    }
}
