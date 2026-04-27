import Foundation

public typealias StopCondition = @Sendable (Session) async -> Bool

public struct Loop: Sendable {
    private let provider: Provider
    private let session: Session
    private let model: String
    private let system: String?
    private let maxTokens: Int
    private let temperature: Double?
    private let stopCondition: StopCondition

    public init(
        provider: Provider,
        session: Session,
        model: String,
        system: String? = nil,
        maxTokens: Int,
        temperature: Double? = nil,
        stopCondition: @escaping StopCondition = { _ in false },
    ) {
        self.provider = provider
        self.session = session
        self.model = model
        self.system = system
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.stopCondition = stopCondition
    }

    public func run() -> AsyncThrowingStream<LoopEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<LoopEvent, Error>.makeStream()

        let childTask = Task {
            do {
                while true {
                    try Task.checkCancellation()

                    if await stopCondition(session) {
                        throw JuliusError.cancelled
                    }

                    let request = try await buildRequest()
                    let responseStream = try await provider.send(request)
                    let message = try await processStream(responseStream, continuation: continuation)

                    if Task.isCancelled { throw JuliusError.cancelled }
                    try await session.append(.assistant(message))

                    if message.stopReason == .stop {
                        continuation.yield(.complete(message))
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
        )
    }

    private func processStream(
        _ responseStream: ResponseStream,
        continuation: AsyncThrowingStream<LoopEvent, Error>.Continuation,
    ) async throws -> AssistantMessage {
        var contentBlocks: [ContentBlock] = []
        var currentText = ""
        var currentReasoning = ""
        var stopReason: StopReason = .stop

        for try await event in responseStream.events {
            switch event {
            case let .textDelta(text):
                currentText += text
                continuation.yield(.delta(.textDelta(text)))
            case let .reasoningDelta(text):
                currentReasoning += text
                continuation.yield(.delta(.reasoningDelta(text)))
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
            }
        }

        return AssistantMessage(content: contentBlocks, stopReason: stopReason)
    }
}
