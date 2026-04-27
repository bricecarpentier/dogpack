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
        case .delta(.done):
            print()
            inReasoning = false
        case .complete:
            break
        }
    }
}

// MARK: - REPL

@MainActor
func runREPL(baseURL: URL, apiKey: String, model: String) async {
    let provider = OpenAIProvider(baseURL: baseURL, apiKey: apiKey)
    let session = InMemorySession()
    let loop = Loop(
        provider: provider,
        session: session,
        model: model,
        maxTokens: 4096,
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

        await session.append(.user(trimmed))

        currentTask = Task {
            do {
                try await displayStream(loop.run())
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
