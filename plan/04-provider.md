# 04 — Provider Protocol + OpenAIProvider

## Status: done

## Depends on
01 (core types), 02 (Transport + MockTransport)

## Scope
- Define `Provider` protocol
- Implement `OpenAIProvider` — serialize request, send via Transport, parse SSE into ProviderEvents
- Choose between Responses API and Chat Completions at implementation time

## Files
| File | Action |
|------|--------|
| `Sources/julius/Provider.swift` | Create — `Provider` protocol |
| `Sources/julius/OpenAI/OpenAIProvider.swift` | Create |
| `Tests/juliusTests/OpenAIProviderTests.swift` | Create |

## Provider protocol
```swift
protocol Provider: Sendable {
    func send(_ request: ProviderRequest) async throws -> ResponseStream
}
```

## OpenAIProvider behavior
- Composed with a `Transport` at init
- `send()` serializes `ProviderRequest` to JSON, calls `transport.send()`
- Parses raw SSE `Data` into `ProviderEvent` stream
- Maps provider-specific JSON shapes to generic `ProviderEvent`/`ContentBlock`
- Supports `Configuration` struct for provider-specific settings (reasoning effort, etc.)

## Implementation

### Test strategy
Three integration tests, all using `MockTransport`:

1. **Full streaming turn** — Build a `ProviderRequest`, create `MockTransport` with canned multi-event SSE JSON (`data: {...}\n\n` lines), create `OpenAIProvider` with that transport, call `send()`, consume all `ProviderEvent`s from `ResponseStream`, verify the sequence (`textDelta`, `reasoningDelta`, `done(.stop)`). Exercises request serialization → transport → SSE parsing → event mapping end-to-end.

2. **Request JSON shape verification** — Use a capturing variant of `MockTransport` to capture the `Data` passed to `send()`, parse it back as JSON, and verify it contains the correct `model`, `messages`, `system`, `maxTokens`, `temperature` fields.

3. **Malformed SSE surfaces `JuliusError.responseParsingFailed`** — `MockTransport` yields garbage data (not valid SSE JSON). Provider parses it and throws `responseParsingFailed`.

Cancel wiring is implicitly tested in test 1 (`ResponseStream.cancel` is non-nil and callable).

## Acceptance criteria
- [ ] `mise run build` passes
- [ ] SSE JSON → `ProviderEvent` parsing works for text, reasoning, and done events
- [ ] Request serialization produces valid JSON with correct fields
- [ ] Cancel closure from `InFlight` is wired through to `ResponseStream`
- [ ] Malformed SSE data surfaces as `JuliusError.responseParsingFailed`
