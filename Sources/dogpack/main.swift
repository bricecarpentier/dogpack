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

// MARK: - Output Formatting

func printContentBlock(_ block: ContentBlock) {
    switch block {
    case let .text(text):
        print(text)
    case let .reasoning(text):
        for line in text.components(separatedBy: "\n") {
            print("| \(line)")
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
                let message = try await loop.run()
                for block in message.content {
                    printContentBlock(block)
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
