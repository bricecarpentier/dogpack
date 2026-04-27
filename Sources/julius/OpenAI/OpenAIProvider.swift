import Foundation

public struct OpenAIConfiguration: Sendable {
    public var reasoningEffort: String?

    public init(reasoningEffort: String? = nil) {
        self.reasoningEffort = reasoningEffort
    }
}

public typealias TransportFactory = @Sendable (URL, String?) -> Transport

public final class OpenAIProvider: Provider, @unchecked Sendable {
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

        if let tools = request.tools, !tools.isEmpty {
            body["tools"] = tools.map { tool in
                var function: [String: Any] = [
                    "name": tool.name,
                    "description": tool.description,
                ]
                function["parameters"] = jsonify(tool.inputSchema)
                return [
                    "type": "function",
                    "function": function,
                ]
            }
            body["tool_choice"] = serializeToolChoice(request.toolChoice ?? .auto)
        } else {
            body["tool_choice"] = "none"
        }

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
                case .toolUse:
                    return nil
                }
            }.joined()

            let toolCalls = msg.content.compactMap { block -> [String: Any]? in
                if case let .toolUse(call) = block {
                    return [
                        "id": call.id,
                        "type": "function",
                        "function": [
                            "name": call.name,
                            "arguments": call.arguments,
                        ],
                    ]
                }
                return nil
            }

            var result: [String: Any] = ["role": "assistant"]
            if !text.isEmpty {
                result["content"] = text
            }
            if !toolCalls.isEmpty {
                result["tool_calls"] = toolCalls
            }
            return result
        case let .toolResult(toolResult):
            return [
                "role": "tool",
                "tool_call_id": toolResult.callId,
                "content": toolResult.output,
            ]
        }
    }

    private func serializeToolChoice(_ choice: ToolChoice) -> Any {
        switch choice {
        case .auto: "auto"
        case .none: "none"
        case .required: "required"
        case let .named(name): ["type": "function", "function": ["name": name]]
        }
    }

    private func jsonify(_ value: JSONValue) -> Any {
        switch value {
        case .null: NSNull()
        case let .bool(boolValue): boolValue
        case let .int(intValue): intValue
        case let .double(doubleValue): doubleValue
        case let .string(stringValue): stringValue
        case let .array(arrayValue): arrayValue.map(jsonify)
        case let .object(objectValue): objectValue.mapValues(jsonify)
        }
    }

    // MARK: - SSE → ProviderEvent Parsing

    private struct PendingToolCall {
        var id: String = ""
        var name: String = ""
        var arguments: String = ""

        func toToolCall() -> ToolCall {
            ToolCall(id: id, name: name, arguments: arguments)
        }
    }

    private func mapToProviderEvents(inFlight: InFlight) -> ResponseStream {
        let (stream, continuation) = AsyncThrowingStream<ProviderEvent, Error>.makeStream()

        let task = Task {
            var pendingToolCalls: [Int: PendingToolCall] = [:]

            do {
                for try await data in inFlight.events {
                    let events = try parseChunk(data, pendingToolCalls: &pendingToolCalls)
                    for event in events {
                        continuation.yield(event)
                    }
                }

                // Flush any remaining tool calls when stream ends
                for (_, pending) in pendingToolCalls.sorted(by: { $0.key < $1.key }) {
                    continuation.yield(.toolCall(pending.toToolCall()))
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

    private func parseChunk(
        _ data: Data,
        pendingToolCalls: inout [Int: PendingToolCall],
    ) throws -> [ProviderEvent] {
        let choice = try parseChoice(from: data)
        var events: [ProviderEvent] = []

        if let delta = choice["delta"] as? [String: Any] {
            appendDeltaEvents(from: delta, into: &events)
            accumulateToolCallDeltas(from: delta, into: &pendingToolCalls)
        }

        if let finishReason = choice["finish_reason"] as? String {
            let flushedCalls = flushFinishReason(
                finishReason,
                pendingToolCalls: &pendingToolCalls,
            )
            for call in flushedCalls {
                events.append(.toolCall(call))
            }
            appendDoneEvent(finishReason, into: &events)
        }

        return events
    }

    private func parseChoice(from data: Data) throws -> [String: Any] {
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
        return choice
    }

    private func appendDeltaEvents(from delta: [String: Any], into events: inout [ProviderEvent]) {
        if let content = delta["content"] as? String, !content.isEmpty {
            events.append(.textDelta(content))
        }
        if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
            events.append(.reasoningDelta(reasoning))
        }
    }

    private func accumulateToolCallDeltas(
        from delta: [String: Any],
        into pendingToolCalls: inout [Int: PendingToolCall],
    ) {
        guard let toolCallDeltas = delta["tool_calls"] as? [[String: Any]] else { return }
        for tcDelta in toolCallDeltas {
            guard let index = tcDelta["index"] as? Int else { continue }
            var pending = pendingToolCalls[index] ?? PendingToolCall()
            if let toolCallId = tcDelta["id"] as? String { pending.id = toolCallId }
            if let function = tcDelta["function"] as? [String: Any] {
                if let functionName = function["name"] as? String { pending.name = functionName }
                if let args = function["arguments"] as? String { pending.arguments += args }
            }
            pendingToolCalls[index] = pending
        }
    }

    private func flushFinishReason(
        _ finishReason: String,
        pendingToolCalls: inout [Int: PendingToolCall],
    ) -> [ToolCall] {
        guard finishReason == "tool_calls" else { return [] }
        let calls = pendingToolCalls.sorted(by: { $0.key < $1.key }).map { $0.value.toToolCall() }
        pendingToolCalls.removeAll()
        return calls
    }

    private func appendDoneEvent(_ finishReason: String, into events: inout [ProviderEvent]) {
        let reason: StopReason = switch finishReason {
        case "stop": .stop
        case "length": .length
        case "content_filter": .contentFilter
        case "tool_calls": .toolUse
        default: .stop
        }
        events.append(.done(reason))
    }
}
