import Foundation
import julius

// MARK: - CLI Parsing

struct CLIOptions {
    var url: String
    var apiKey: String
    var model: String
}

private func printUsage() {
    let name = CommandLine.arguments.first ?? "dogpack"
    print("Usage: \(name) --url <base-url> --api-key <key> --model <model>")
    print()
    print("Options:")
    print("  --url      Provider base URL up to /v1 (e.g. https://api.openai.com/v1)")
    print("  --api-key  API key")
    print("  --model    Model name (e.g. gpt-4o-mini)")
}

private func parseArguments() -> CLIOptions? {
    let args = Array(CommandLine.arguments.dropFirst())
    var parsed: [String: String] = [:]
    var idx = 0
    while idx < args.count {
        let arg = args[idx]
        if arg.hasPrefix("--") {
            let withoutPrefix = String(arg.dropFirst(2))
            if let equalSign = withoutPrefix.firstIndex(of: "=") {
                let key = String(withoutPrefix[..<equalSign])
                let value = String(withoutPrefix[equalSign...].dropFirst())
                parsed[key] = value
                idx += 1
            } else if idx + 1 < args.count {
                parsed[withoutPrefix] = args[idx + 1]
                idx += 2
            } else {
                idx += 1
            }
        } else {
            idx += 1
        }
    }

    guard let url = parsed["url"],
          let apiKey = parsed["api-key"],
          let model = parsed["model"]
    else {
        return nil
    }
    return CLIOptions(url: url, apiKey: apiKey, model: model)
}

// MARK: - Output Formatting

private func printContentBlock(_ block: ContentBlock) {
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
private func runREPL(options: CLIOptions) async {
    guard let baseURL = URL(string: options.url) else {
        print("Error: invalid URL '\(options.url)'")
        exit(1)
    }

    let provider = OpenAIProvider(baseURL: baseURL, apiKey: options.apiKey)
    let session = InMemorySession()
    let loop = Loop(
        provider: provider,
        session: session,
        model: options.model,
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
            currentTask = nil
        }

        await currentTask?.value
    }
}

// MARK: - Entry Point

if let options = parseArguments() {
    await runREPL(options: options)
} else {
    printUsage()
    exit(1)
}
