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

## Decision: Option B — AsyncSequence

Callback is a dead end. AsyncSequence is the correct Swift concurrency
primitive — structured backpressure, cancellation propagation, composable.

## Scope
- Change `Loop.run()` to return `AsyncThrowingStream<LoopEvent, Error>`
- Add `LoopEvent` type to `Types.swift`
- Update REPL to iterate the stream and print deltas incrementally
- Rewrite LoopTests to consume the stream

## Design

### New type — `LoopEvent`

Added to `Sources/julius/Types.swift`:

```swift
public enum LoopEvent: Sendable {
    case delta(ProviderEvent)
    case complete(AssistantMessage)
}
```

### `Loop.run()` — return type change

```swift
public func run() -> AsyncThrowingStream<LoopEvent, Error>
```

Internally, `run()` creates an `AsyncThrowingStream` whose continuation
receives events from a child `Task`. The existing while-loop and accumulation
logic moves inside that Task. Key points:

- **Yield `.delta`** for every `.textDelta` / `.reasoningDelta` from the
  provider stream — no buffering, forward immediately.
- **Accumulate in parallel** — keep the local `currentText` / `currentReasoning`
  strings so that `.done` can still build `ContentBlock`s for the
  `AssistantMessage`.
- **Yield `.complete(message)`** only on the final iteration (when
  `stopReason == .stop`), then finish the continuation.
- **Session append stays inside Loop** — `session.append(.assistant(message))`
  remains in `run()`. Loop owns session state; `.complete` is informational.
  Callers don't need to manage session.
- **Cancellation** — use `continuation.onTermination` to cancel the inner Task.
  `Task.checkCancellation()` at loop top and `Task.isCancelled` after
  accumulation continue to work inside the Task.

### REPL — stream consumption

```swift
for try await event in loop.run() {
    switch event {
    case .delta(.textDelta(let text)):
        print(text, terminator: "")
        fflush(stdout)
    case .delta(.reasoningDelta(let text)):
        print("| \(text)", terminator: "")
        fflush(stdout)
    case .delta(.done):
        print() // newline after stream ends
    case .complete:
        break // informational, session already updated
    }
}
```

### Reasoning prefix during streaming

Reasoning deltas arrive as arbitrary fragments (not necessarily line-aligned).
Print each fragment with `| ` prefix only at the start of a new reasoning
block. Track state with a local `var inReasoning = false`:

- On `.reasoningDelta` when `!inReasoning`: print `| `, set `inReasoning = true`
- On `.reasoningDelta` when `inReasoning`: print text directly
- On `.textDelta` or `.done`: set `inReasoning = false`

### Tests — stream consumption helper

Add a small helper to `LoopTests` for non-streaming consumption:

```swift
private func collectMessage(
    _ stream: AsyncThrowingStream<LoopEvent, Error>
) async throws -> AssistantMessage {
    for try await event in stream {
        if case let .complete(message) = event { return message }
    }
    throw JuliusError.cancelled
}
```

Existing tests call `collectMessage(loop.run())` instead of `loop.run()`.
Test assertions on `result.stopReason`, `result.content`, `provider.callCount`,
and `session.messages()` remain identical.

Add one new test: **streaming deltas observed** — collect all `.delta` events
from the stream and assert they arrive in order before `.complete`.

## Files
| File | Action |
|------|--------|
| `Sources/julius/Types.swift` | Modify — add `LoopEvent` enum |
| `Sources/julius/Loop.swift` | Modify — `run()` returns `AsyncThrowingStream<LoopEvent, Error>`, inline accumulation |
| `Sources/dogpack/main.swift` | Modify — iterate stream, print deltas, reasoning prefix logic |
| `Tests/juliusTests/LoopTests.swift` | Modify — `collectMessage` helper, rewrite 4 tests, add streaming-observes-deltas test |
| `Tests/juliusTests/IntegrationTests.swift` | No change — bypasses `Loop`, uses its own `accumulate()` |

## Implementation steps

### Step 1 — Add `LoopEvent` to `Types.swift`

Add `LoopEvent` enum after `ProviderEvent`. Two cases: `.delta(ProviderEvent)`
and `.complete(AssistantMessage)`. Mark `Sendable`.

### Step 2 — Rewrite `Loop.run()`

- Change signature: `func run() -> AsyncThrowingStream<LoopEvent, Error>`
- Create stream with `AsyncThrowingStream.makeStream()`
- Spawn child `Task` that contains the while-loop:
  - `Task.checkCancellation()` at loop top (unchanged)
  - `stopCondition` check (unchanged)
  - Build `ProviderRequest` (unchanged)
  - `provider.send(request)` (unchanged)
  - Inline the old `accumulate()` logic — iterate `responseStream.events`:
    - On `.textDelta`: append to `currentText`, yield `.delta(.textDelta(text))`
    - On `.reasoningDelta`: append to `currentReasoning`, yield `.delta(.reasoningDelta(text))`
    - On `.done`: build `ContentBlock`s, create `AssistantMessage`, `session.append`, yield `.delta(.done(reason))`
  - If `stopReason == .stop`: yield `.complete(message)`, finish continuation, return
  - If `stopReason != .stop`: continue loop (next provider call)
- Set `continuation.onTermination` to cancel the child Task
- Remove the private `accumulate()` method
- Return the stream

### Step 3 — Update `LoopTests`

- Add `collectMessage(_:)` helper function
- `single turn returns immediately`: wrap `loop.run()` in `collectMessage()`, same assertions
- `multi turn loops until stop`: same pattern, same assertions
- `task cancellation throws cancelled`: iterate stream in Task, cancel, expect error
- `stop condition halts loop`: wrap in `collectMessage()`, expect `JuliusError.cancelled`
- Add new test `streaming deltas observed`:
  - Provider returns `[.reasoningDelta("A"), .textDelta("B"), .done(.stop)]`
  - Collect all events into array
  - Assert: deltas arrive in order, last event is `.complete`

### Step 4 — Build + test (julius only)

- `mise run build` — must pass
- `mise run test --filter juliusTests` — all 5 tests pass

### Step 5 — Update REPL in `main.swift`

- Replace `let message = try await loop.run()` with `for try await event in loop.run()`
- Add `var inReasoning = false` before the loop
- Handle `.delta(.textDelta)`: print text, `fflush(stdout)`, `inReasoning = false`
- Handle `.delta(.reasoningDelta)`: print `| ` prefix if `!inReasoning`, then text, `fflush(stdout)`, `inReasoning = true`
- Handle `.delta(.done)`: print newline, `inReasoning = false`
- Handle `.complete`: no-op (session already updated by Loop)
- Remove `printContentBlock(_:)` function (no longer needed)

### Step 6 — Build + test (full stack)

- `mise run build` — must pass
- `mise run test` — all tests pass (julius + integration)

## Acceptance criteria
- [ ] `mise run build` passes
- [ ] `mise run test` passes
- [ ] REPL prints text tokens as they arrive
- [ ] Reasoning deltas display with `| ` prefix as they stream
- [ ] Full response is still accumulated into session history
