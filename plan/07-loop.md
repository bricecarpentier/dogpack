# 06 — Loop (ReAct Loop)

## Status: done

## Depends on
01, 02, 03, 04 (all done)

## Scope
- Implement the ReAct loop — repeatedly calls the provider until the model stops
- No tool support yet (tools blocked via `tool_choice: "none"`)
- Add `JuliusError.cancelled`

## Files
| File | Action |
|------|--------|
| `Sources/julius/Loop.swift` | Create |
| `Sources/julius/Types.swift` | Modify — add `.cancelled` to `JuliusError` |
| `Sources/julius/OpenAI/OpenAIProvider.swift` | Modify — serialize `tool_choice: "none"` |
| `Tests/juliusTests/LoopTests.swift` | Create |

## Loop behavior
- Init takes: `Provider`, `Session`, `model`, `system`, `maxTokens`, `temperature`, `stopCondition`
- `stopCondition`: `@Sendable (Session) async -> Bool` — returns `true` to halt. Default: `{ _ in false }`
- `func run() async throws -> AssistantMessage`
- Loop:
  1. Check `Task.isCancelled` → throw `JuliusError.cancelled`
  2. Check `stopCondition(session)` → throw `JuliusError.cancelled`
  3. Build `ProviderRequest` from session history
  4. `provider.send(request)` → accumulate `ResponseStream` into `AssistantMessage` (private helper)
  5. `session.append(.assistant(message))`
  6. If `stopReason == .stop` → return message
  7. Else loop

## StopCondition
```swift
typealias StopCondition = @Sendable (Session) async -> Bool
```
Default: `{ _ in false }` (no cap).

Example capped strategy:
```swift
{ session in
    await session.messages().count > 20
}
```

## Implementation

### Test strategy
Integration tests using `MockTransport` + `InMemorySession`:

1. **Single-turn (no loop)** — MockTransport returns a response with `stopReason == .stop`. Verify `run()` returns immediately with correct message, session has 2 messages (user + assistant).

2. **Multi-turn (loops on `.length`)** — First call returns `stopReason == .length`, second returns `stopReason == .stop`. Verify the loop iterates twice, session accumulates both assistant messages, and final result is the second message.

3. **Cancellation** — Start `run()` in a `Task`, cancel it mid-stream. Verify `JuliusError.cancelled` is thrown.

4. **Stop condition halts** — Pass a stop condition that returns `true` after 1 message. Verify `JuliusError.cancelled` is thrown.

## Acceptance criteria
- [ ] `mise run build` passes
- [ ] Single-turn returns immediately
- [ ] Multi-turn loops until `.stop`
- [ ] Task cancellation throws `JuliusError.cancelled`
- [ ] Stop condition throws `JuliusError.cancelled`
- [ ] `tool_choice: "none"` sent in serialized request
