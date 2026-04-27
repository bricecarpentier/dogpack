# 10 — ArgumentParser Refactor

## Status: not started

## Depends on
08 (CLI Test Client)

## Problem
`Sources/dogpack/main.swift` hand-rolls CLI argument parsing (`parseArguments()`,
`printUsage()`, manual `--key value` splitting). This is fragile, produces
minimal help output, and lacks validation, shell completions, and near-miss
suggestions.

## Scope
Replace the hand-rolled parser with [Swift ArgumentParser](https://github.com/apple/swift-argument-parser).

## Files
| File | Action |
|------|--------|
| `Package.swift` | Modify — add `swift-argument-parser` dependency, wire to `dogpack` target |
| `Sources/dogpack/main.swift` | Modify — replace `CLIOptions`/`parseArguments()`/`printUsage()` with `ParsableCommand` |

## Design

### Package.swift

Add product dependency:

```swift
dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.3"),
],
```

Add to `dogpack` target:

```swift
.executableTarget(name: "dogpack", dependencies: [
    "julius",
    .product(name: "ArgumentParser", package: "swift-argument-parser"),
]),
```

### ParsableCommand

Replace `CLIOptions` + `parseArguments()` + `printUsage()` with:

```swift
import ArgumentParser

@main
struct Dogpack: ParsableCommand {
    @Option(help: "Provider base URL up to /v1 (e.g. https://api.openai.com/v1)")
    var url: String

    @Option(help: "API key")
    var apiKey: String

    @Option(help: "Model name (e.g. gpt-4o-mini)")
    var model: String

    mutating func run() throws {
        let options = CLIOptions(url: url, apiKey: apiKey, model: model)
        // existing REPL logic extracted to runREPL(options:)
    }
}
```

The entry point block at the bottom of `main.swift` goes away — `@main`
on `Dogpack` replaces it.

### What stays unchanged

- `CLIOptions` struct (kept as internal data transfer, or inlined)
- `printContentBlock(_:)` — formatting logic
- `runREPL(options:)` — REPL loop, SIGINT handler, task management

## Migration checklist

1. Add `swift-argument-parser` to `Package.swift` dependencies
2. Add `ArgumentParser` dependency to `dogpack` target
3. Add `import ArgumentParser` to `main.swift`
4. Create `Dogpack: ParsableCommand` with `@main`, `@Option` properties
5. Wire `mutating func run() throws` to call existing REPL
6. Remove `parseArguments()`, `printUsage()`, and the bottom-level `if/else` entry point
7. Resolve `swift-tools-version` if needed (ArgumentParser 1.5+ requires 5.9+; we're on 6.1)

## Acceptance criteria
- [ ] `mise run build` passes
- [ ] `mise run test` passes
- [ ] `dogpack --help` prints ArgumentParser-generated usage with descriptions
- [ ] Missing required option produces clear error with near-miss suggestions
- [ ] `dogpack --url ... --api-key ... --model ...` runs the REPL as before

## Implementation plan

Decision: inline `CLIOptions` into the `Dogpack` struct rather than keeping a separate data-transfer type.

### File 1: `Package.swift`

- Add `dependencies: [...]` array with `swift-argument-parser` from 1.5.3
- Add `.product(name: "ArgumentParser", package: "swift-argument-parser")` to `dogpack` target dependencies

### File 2: `Sources/dogpack/main.swift`

- Remove: `CLIOptions` struct, `printUsage()`, `parseArguments()`, entry point block (lines 133-137)
- Add: `import ArgumentParser`, `@main struct Dogpack: ParsableCommand`
- Modify: `runREPL` signature to take `(url: String, apiKey: String, model: String)` directly

### Execution order

1. Edit `Package.swift` — add dependency
2. Edit `main.swift` — refactor parser, keep REPL logic
3. Run `mise run build` to verify
4. Run `mise run test` to verify
5. Update plan status
