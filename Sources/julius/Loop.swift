import Foundation

public typealias StopCondition = @Sendable (Session) async -> Bool

public struct Loop: Sendable {
    private let provider: Provider
    private let session: Session
    private let model: String
    private let system: String
    private let maxTokens: Int
    private let temperature: Double?
    private let stopCondition: StopCondition
    private let tools: [ToolDefinition]
    private let toolChoice: ToolChoice?
    private let compactor: Compactor?

    public init(
        provider: Provider,
        session: Session,
        model: String,
        system: String,
        maxTokens: Int,
        temperature: Double? = nil,
        stopCondition: @escaping StopCondition = { _ in false },
        tools: [ToolDefinition] = [],
        toolChoice: ToolChoice? = nil,
        compactor: Compactor? = nil,
    ) {
        self.provider = provider
        self.session = session
        self.model = model
        self.system = system
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.stopCondition = stopCondition
        self.tools = tools
        self.toolChoice = toolChoice
        self.compactor = compactor
    }

    public func run() -> AsyncThrowingStream<LoopEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<LoopEvent, Error>.makeStream()

        let childTask = Task {
            do {
                var lastUsage: Usage?

                while true {
                    try Task.checkCancellation()

                    if await stopCondition(session) {
                        throw JuliusError.cancelled
                    }

                    // Run compaction before building request (best-effort)
                    if let compactor {
                        try? await compactor.compactIfNeeded(
                            session,
                            lastUsage: lastUsage,
                            system: system,
                            provider: provider,
                            model: model,
                        )
                    }

                    let request = try await buildRequest()
                    let responseStream = try await provider.send(request)
                    let result = try await processStream(responseStream, continuation: continuation)

                    lastUsage = result.usage
                    if Task.isCancelled { throw JuliusError.cancelled }
                    try await session.append(.assistant(result.message))

                    if result.message.stopReason == .stop {
                        continuation.yield(.complete(result.message))
                        continuation.finish()
                        return
                    }

                    if result.message.stopReason == .toolUse {
                        let calls = result.message.content.compactMap { block -> ToolCall? in
                            if case let .toolUse(call) = block { return call }
                            return nil
                        }
                        continuation.yield(.toolCalls(calls))
                        continuation.yield(.complete(result.message))
                        continuation.finish()
                        return
                    }
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

    private func buildRequest() async throws -> ProviderRequest {
        let history = await session.messages()
        return ProviderRequest(
            model: model,
            system: system,
            messages: history,
            maxTokens: maxTokens,
            temperature: temperature,
            tools: tools,
            toolChoice: toolChoice,
        )
    }

    private struct StreamResult {
        var message: AssistantMessage
        var usage: Usage?
    }

    private func processStream(
        _ responseStream: ResponseStream,
        continuation: AsyncThrowingStream<LoopEvent, Error>.Continuation,
    ) async throws -> StreamResult {
        var contentBlocks: [ContentBlock] = []
        var currentText = ""
        var currentReasoning = ""
        var stopReason: StopReason = .stop
        var usage: Usage?

        for try await event in responseStream.events {
            switch event {
            case let .textDelta(text):
                currentText += text
                continuation.yield(.delta(.textDelta(text)))
            case let .reasoningDelta(text):
                currentReasoning += text
                continuation.yield(.delta(.reasoningDelta(text)))
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
                continuation.yield(.delta(.toolCall(call)))
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
                continuation.yield(.delta(.done(reason)))
            case let .usage(receivedUsage):
                usage = receivedUsage
            }
        }

        return StreamResult(
            message: AssistantMessage(content: contentBlocks, stopReason: stopReason),
            usage: usage,
        )
    }
}
