import ArgumentParser
import Foundation
import julius

// MARK: - CLI Options

struct DogpackOptions: ParsableArguments {
    @Option(help: "Provider base URL up to /v1 (e.g. https://api.openai.com/v1)")
    var url: String

    @Option(help: "API key")
    var apiKey: String

    @Option(help: "Model name (e.g. gpt-4o-mini)")
    var model: String
}

let options = DogpackOptions.parseOrExit()

guard let baseURL = URL(string: options.url) else {
    DogpackOptions.exit(withError: ValidationError("invalid URL '\(options.url)'"))
}

// MARK: - Built-in Tools

let builtinTools: [ToolDefinition] = [
    ToolDefinition(
        name: "get_weather",
        description: "Get the current weather for a city",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "city": .object([
                    "type": .string("string"),
                    "description": .string("City name"),
                ]),
            ]),
            "required": .array([.string("city")]),
        ]),
    ),
]

func executeBuiltinTool(_ call: ToolCall) -> ToolResult {
    switch call.name {
    case "get_weather":
        let city = extractCity(from: call.arguments)
        return ToolResult(callId: call.id, output: weather(for: city))
    default:
        return ToolResult(callId: call.id, output: "Unknown tool")
    }
}

private func extractCity(from arguments: String) -> String {
    guard let data = arguments.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let city = json["city"] as? String
    else { return "" }
    return city.lowercased()
}

private func weather(for city: String) -> String {
    if city.contains("venice") || city.contains("venezia") {
        "24°C, sunny"
    } else if city.contains("paris") {
        "14°C, cloudy"
    } else if city.contains("hossegor") {
        "16°C, rainy af"
    } else {
        "I don't know, look at the window maybe?"
    }
}

// MARK: - Stream Display

@MainActor
func displayStream(_ stream: AsyncThrowingStream<LoopEvent, Error>) async throws {
    var inReasoning = false
    for try await event in stream {
        switch event {
        case let .delta(.textDelta(text)):
            print(text, terminator: "")
            fflush(stdout)
            inReasoning = false
        case let .delta(.reasoningDelta(text)):
            let lines = text.components(separatedBy: "\n")
            for (idx, line) in lines.enumerated() {
                if idx > 0 {
                    print()
                    print("| ", terminator: "")
                } else if !inReasoning {
                    print("| ", terminator: "")
                }
                print(line, terminator: "")
            }
            inReasoning = true
            fflush(stdout)
        case let .delta(.toolCall(call)):
            print("\n[tool call: \(call.name)(\(call.arguments))]", terminator: "")
            fflush(stdout)
            inReasoning = false
        case .delta(.done):
            print()
            inReasoning = false
        case .toolCalls:
            break
        case .complete:
            break
        }
    }
}

// MARK: - REPL

@MainActor
func printEvent(_ event: LoopEvent, inReasoning: Bool) -> Bool {
    switch event {
    case let .delta(.textDelta(text)):
        if inReasoning { print() }
        print(text, terminator: "")
        fflush(stdout)
        return false
    case let .delta(.reasoningDelta(text)):
        let lines = text.components(separatedBy: "\n")
        for (idx, line) in lines.enumerated() {
            if idx > 0 {
                print()
                print("| ", terminator: "")
            } else if !inReasoning {
                print("| ", terminator: "")
            }
            print(line, terminator: "")
        }
        fflush(stdout)
        return true
    case let .delta(.toolCall(call)):
        print("\n[tool call: \(call.name)(\(call.arguments))]", terminator: "")
        fflush(stdout)
        return false
    case .delta(.done):
        print()
        return false
    case .toolCalls, .complete:
        return inReasoning
    }
}

@MainActor
func handleToolCycle(provider: OpenAIProvider, session: InMemorySession, model: String) async throws {
    while true {
        let loop = Loop(
            provider: provider,
            session: session,
            model: model,
            maxTokens: 4096,
            tools: builtinTools,
        )

        var toolCalls: [ToolCall] = []
        var inReasoning = false

        for try await event in loop.run() {
            inReasoning = printEvent(event, inReasoning: inReasoning)
            if case let .toolCalls(calls) = event {
                toolCalls = calls
            }
        }

        guard !toolCalls.isEmpty else { break }

        for call in toolCalls {
            let result = executeBuiltinTool(call)
            print("[tool result: \(result.output)]")
            try await session.append(.toolResult(result))
        }
    }
}

@MainActor
func runREPL(baseURL: URL, apiKey: String, model: String) async {
    let provider = OpenAIProvider(baseURL: baseURL, apiKey: apiKey)
    let session = InMemorySession()

    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    signal(SIGINT, SIG_IGN)
    var currentTask: Task<Void, Never>?

    sigintSource.setEventHandler {
        currentTask?.cancel()
    }
    sigintSource.resume()

    while true {
        print("> ", terminator: "")
        fflush(stdout)

        guard let line = readLine() else {
            print()
            return
        }

        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }
        if trimmed == "/quit" { return }

        try? await session.append(.user(trimmed))

        currentTask = Task {
            do {
                try await handleToolCycle(provider: provider, session: session, model: model)
            } catch is CancellationError {
                print("\n[interrupted]")
            } catch JuliusError.cancelled {
                print("\n[interrupted]")
            } catch {
                print("Error: \(error)")
            }
        }

        await currentTask?.value
    }
}

await runREPL(baseURL: baseURL, apiKey: options.apiKey, model: options.model)
