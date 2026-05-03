import julius

/// The agent runtime. Owns a julius Loop, Session, and ToolRegistry.
/// Runs turns, dispatches tool calls, feeds results back.
public final class Agent: Sendable {
    private let provider: Provider
    private let session: Session
    private let registry: ToolRegistry
    private let model: String
    private let system: String
    private let maxTokens: Int

    public init(
        provider: Provider,
        session: Session,
        registry: ToolRegistry,
        model: String,
        system: String,
        maxTokens: Int = 4096,
    ) {
        self.provider = provider
        self.session = session
        self.registry = registry
        self.model = model
        self.system = system
        self.maxTokens = maxTokens
    }

    /// Run a single user turn through the loop, executing any tool calls.
    /// Streams agent events — text/reasoning deltas, tool calls, results, and the final message.
    public func runTurn(_ userMessage: String) -> AsyncThrowingStream<AgentEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<AgentEvent, Error>.makeStream()

        let config = TurnConfig(
            provider: provider,
            session: session,
            registry: registry,
            model: model,
            system: system,
            maxTokens: maxTokens,
        )

        let childTask = Task {
            do {
                try await config.session.append(.user(userMessage))

                while true {
                    let toolCalls = try await Self.runLoopIteration(
                        config: config,
                        continuation: continuation,
                    )

                    if toolCalls.isEmpty {
                        let messages = await config.session.messages()
                        guard case let .assistant(finalMessage) = messages.last else {
                            fatalError("expected assistant message as last session entry after loop iteration")
                        }
                        continuation.yield(.complete(finalMessage))
                        continuation.finish()
                        return
                    }

                    continuation.yield(.toolCalls(toolCalls))
                    try await Self.executeAndFeedResults(
                        toolCalls: toolCalls,
                        config: config,
                        continuation: continuation,
                    )
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }

        continuation.onTermination = { _ in
            childTask.cancel()
        }

        return stream
    }

    // MARK: - Private

    /// Captures all agent configuration needed for a turn.
    private struct TurnConfig {
        let provider: Provider
        let session: Session
        let registry: ToolRegistry
        let model: String
        let system: String
        let maxTokens: Int
    }

    /// Run a single loop iteration, forwarding streaming deltas.
    /// Returns any tool calls emitted by the model.
    private static func runLoopIteration(
        config: TurnConfig,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation,
    ) async throws -> [ToolCall] {
        let definitions = await config.registry.definitions
        let loop = Loop(
            provider: config.provider,
            session: config.session,
            model: config.model,
            system: config.system,
            maxTokens: config.maxTokens,
            tools: definitions.isEmpty ? nil : definitions,
        )

        var toolCalls: [ToolCall] = []

        for try await event in loop.run() {
            switch event {
            case let .delta(.textDelta(text)):
                continuation.yield(.textDelta(text))
            case let .delta(.reasoningDelta(text)):
                continuation.yield(.reasoningDelta(text))
            case .delta(.toolCall), .delta(.done), .delta(.usage):
                break
            case let .toolCalls(calls):
                toolCalls = calls
            case .complete:
                break
            }
        }

        return toolCalls
    }

    /// Execute tool calls in parallel, capturing errors as tool results.
    /// Results are yielded and appended to session in original call order
    /// for deterministic session history.
    private static func executeAndFeedResults(
        toolCalls: [ToolCall],
        config: TurnConfig,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation,
    ) async throws {
        let results: [String: ToolResult] = try await withThrowingTaskGroup(
            of: ToolResult.self,
        ) { group in
            for call in toolCalls {
                group.addTask {
                    do {
                        return try await config.registry.execute(call)
                    } catch {
                        return ToolResult(callId: call.id, output: "Error: \(error)")
                    }
                }
            }
            return try await group.reduce(into: [:]) { $0[$1.callId] = $1 }
        }

        for call in toolCalls {
            guard let result = results[call.id] else { continue }
            continuation.yield(.toolResult(result))
            try await config.session.append(.toolResult(result))
        }
    }
}
