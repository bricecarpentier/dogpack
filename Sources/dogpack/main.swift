import ArgumentParser
import Foundation
import julius
import zoomies

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

// MARK: - REPL

@MainActor
func printEvent(_ event: AgentEvent, inReasoning: Bool) -> Bool {
    switch event {
    case let .textDelta(text):
        if inReasoning { print() }
        print(text, terminator: "")
        fflush(stdout)
        return false
    case let .reasoningDelta(text):
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
    case let .toolCalls(calls):
        for call in calls {
            print("\n[tool call: \(call.name)(\(call.arguments))]", terminator: "")
        }
        fflush(stdout)
        return false
    case let .toolResult(result):
        print("\n[tool result: \(result.output)]", terminator: "")
        fflush(stdout)
        return false
    case .complete:
        print()
        return false
    }
}

@MainActor
func runREPL(baseURL: URL, apiKey: String, model: String) async {
    let provider = OpenAIProvider(baseURL: baseURL, apiKey: apiKey)
    let session = InMemorySession()
    let registry = ToolRegistry()
    try? await registry.register(WeatherTool())

    let agent = Agent(
        provider: provider,
        session: session,
        registry: registry,
        model: model,
        system: "You are a helpful assistant.",
    )

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

        currentTask = Task {
            do {
                var inReasoning = false
                for try await event in agent.runTurn(trimmed) {
                    inReasoning = printEvent(event, inReasoning: inReasoning)
                }
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
