# 09 — Streaming Display

## Status: not started

## Depends on
07 (Loop)

## Problem
The REPL displays nothing until the full response is received. The transport
and provider layers stream SSE deltas in real time, but `Loop.accumulate()`
buffers all events into complete `ContentBlock`s before returning. The caller
(the REPL) only receives the final `AssistantMessage` after the stream ends.

## Root cause
`Loop.run()` → `accumulate()` collects every `.textDelta` / `.reasoningDelta`
into local strings and only materializes `ContentBlock`s on `.done`. The REPL
awaits the full return value before printing.

## Scope
- Add a streaming callback or secondary output to `Loop` so callers can observe
  deltas as they arrive
- Update the REPL to print text/reasoning deltas incrementally
- Reasoning lines should still get the `| ` prefix as they stream in

## Files
| File | Action |
|------|--------|
| `Sources/julius/Loop.swift` | Modify — add delta callback or stream output |
| `Sources/dogpack/main.swift` | Modify — wire REPL to stream output |

## Design decision

Two viable options. Decision deferred.

### Option A — Callback

Add an optional `onDelta: ((ProviderEvent) -> Void)?` parameter to `Loop` init.

```swift
struct Loop {
    private let onDelta: ((ProviderEvent) -> Void)?

    init(..., onDelta: ((ProviderEvent) -> Void)? = nil) { ... }

    func run() async throws -> AssistantMessage  // unchanged
}
```

`accumulate()` forwards each event to `onDelta` while still buffering.

**Pros:**
- Minimal API change — `run()` signature unchanged, existing callers unaffected
- Default argument means zero breakage
- Simple to implement and test

**Cons:**
- Synchronous only — can't `await` inside the callback
- Single consumer — can't fan out to multiple listeners
- Caller must manage thread safety if callback touches shared state
- Doesn't compose well as a building block for other consumers

### Option B — AsyncSequence (LoopEvent)

Replace `run()` return type with `AsyncThrowingStream<LoopEvent, Error>`.

```swift
public enum LoopEvent {
    case delta(ProviderEvent)
    case complete(AssistantMessage)
}

struct Loop {
    func run() -> AsyncThrowingStream<LoopEvent, Error>
}
```

Callers iterate:
```swift
for try await event in loop.run() {
    switch event {
    case .delta(.textDelta(let text)): print(text, terminator: "")
    case .delta(.reasoningDelta(let text)): print("| \(text)")
    case .complete(let message): session.append(.assistant(message))
    }
}
```

**Pros:**
- Structured concurrency — natural backpressure and cancellation
- Multiple consumers can share the stream
- Composable — downstream consumers (TUI, HTTP bridge, logging) all use the same interface
- The loop becomes a reusable building block, not a CLI-specific tool

**Cons:**
- Breaking API change — all existing callers and tests must be rewritten
- Session append responsibility shifts to the caller (was inside `run()`)
- More complexity in `Loop.run()` — must manage a stream continuation
- Non-streaming callers need a helper to reduce into `AssistantMessage`

## Files
| File | Action |
|------|--------|
| `Sources/julius/Loop.swift` | Modify — add streaming output |
| `Sources/julius/Types.swift` | Modify — add `LoopEvent` (option B only) |
| `Sources/dogpack/main.swift` | Modify — wire REPL to stream output |
| `Tests/juliusTests/LoopTests.swift` | Modify — update existing tests, add streaming test |
| `Tests/juliusTests/IntegrationTests.swift` | Modify — update if `run()` signature changes |

## Acceptance criteria
- [ ] `mise run build` passes
- [ ] `mise run test` passes
- [ ] REPL prints text tokens as they arrive
- [ ] Reasoning deltas display with `| ` prefix as they stream
- [ ] Full response is still accumulated into session history
