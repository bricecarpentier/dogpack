import Foundation

public struct OpenAIConfiguration: Sendable {
    public var reasoningEffort: String?

    public init(reasoningEffort: String? = nil) {
        self.reasoningEffort = reasoningEffort
    }
}

public typealias TransportFactory = @Sendable (URL, String?) -> Transport

final public class OpenAIProvider: Provider, @unchecked Sendable {
    static let endpoint = "/chat/completions"

    private let baseURL: URL
    private let apiKey: String?
    private let makeTransport: TransportFactory
    private let configuration: OpenAIConfiguration

    public init(
        baseURL: URL,
        apiKey: String? = nil,
        configuration: OpenAIConfiguration = OpenAIConfiguration(),
        makeTransport: @escaping TransportFactory = { url, key in
            HTTPTransport(url: url, apiKey: key)
        },
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.configuration = configuration
        self.makeTransport = makeTransport
    }

    public func send(_ request: ProviderRequest) async throws -> ResponseStream {
        let fullURL = baseURL.appendingPathComponent(Self.endpoint)
        let transport = makeTransport(fullURL, apiKey)
        let data = try serializeRequest(request)
        let inFlight = try await transport.send(data)
        return mapToProviderEvents(inFlight: inFlight)
    }

    // MARK: - Request Serialization

    private func serializeRequest(_ request: ProviderRequest) throws -> Data {
        var body: [String: Any] = try [
            "model": request.model,
            "messages": request.messages.map(serializeMessage),
            "max_tokens": request.maxTokens,
            "stream": true,
        ]

        if let system = request.system {
            body["system"] = system
        }
        if let temperature = request.temperature {
            body["temperature"] = temperature
        }
        if let effort = configuration.reasoningEffort {
            body["reasoning_effort"] = effort
        }
        body["tool_choice"] = "none"

        do {
            return try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw JuliusError.requestSerializationFailed(error.localizedDescription)
        }
    }

    private func serializeMessage(_ message: Message) throws -> [String: Any] {
        switch message {
        case let .user(text):
            return ["role": "user", "content": text]
        case let .assistant(msg):
            let text = msg.content.compactMap { block -> String? in
                switch block {
                case let .text(text):
                    return text
                case .reasoning:
                    return nil
                }
            }.joined()
            return ["role": "assistant", "content": text]
        }
    }

    // MARK: - SSE → ProviderEvent Parsing

    private func mapToProviderEvents(inFlight: InFlight) -> ResponseStream {
        let (stream, continuation) = AsyncThrowingStream<ProviderEvent, Error>.makeStream()

        let task = Task {
            do {
                for try await data in inFlight.events {
                    let events = try parseChunk(data)
                    for event in events {
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        return ResponseStream(
            events: stream,
            cancel: {
                task.cancel()
                await inFlight.cancel()
            },
        )
    }

    private func parseChunk(_ data: Data) throws -> [ProviderEvent] {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw JuliusError.responseParsingFailed("Invalid JSON in response chunk: \(error.localizedDescription)")
        }

        guard let object = json as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let choice = choices.first
        else {
            throw JuliusError.responseParsingFailed("Missing 'choices' in response chunk")
        }

        var events: [ProviderEvent] = []

        if let delta = choice["delta"] as? [String: Any] {
            // Content delta
            if let content = delta["content"] as? String, !content.isEmpty {
                events.append(.textDelta(content))
            }
            // Reasoning delta
            if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                events.append(.reasoningDelta(reasoning))
            }
        }

        // Finish reason
        if let finishReason = choice["finish_reason"] as? String {
            switch finishReason {
            case "stop":
                events.append(.done(.stop))
            case "length":
                events.append(.done(.length))
            case "content_filter":
                events.append(.done(.contentFilter))
            default:
                events.append(.done(.stop))
            }
        }

        return events
    }
}
