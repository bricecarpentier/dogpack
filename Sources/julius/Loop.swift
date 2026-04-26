import Foundation

typealias StopCondition = @Sendable (Session) async -> Bool

struct Loop {
    private let provider: Provider
    private let session: Session
    private let model: String
    private let system: String?
    private let maxTokens: Int
    private let temperature: Double?
    private let stopCondition: StopCondition

    init(
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

    func run() async throws -> AssistantMessage {
        while true {
            try Task.checkCancellation()

            if await stopCondition(session) {
                throw JuliusError.cancelled
            }

            let history = await session.messages()
            let request = ProviderRequest(
                model: model,
                system: system,
                messages: history,
                maxTokens: maxTokens,
                temperature: temperature,
            )

            let responseStream = try await provider.send(request)
            let message = try await accumulate(responseStream)
            if Task.isCancelled { throw JuliusError.cancelled }
            try await session.append(.assistant(message))

            if message.stopReason == .stop {
                return message
            }
        }
    }

    // MARK: - Private

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
}
