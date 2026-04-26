# 04 — Provider Protocol + OpenAIProvider

## Status: not started

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

## Tests use MockTransport
- Feed canned SSE JSON payloads through provider
- Verify correct `ProviderEvent` sequence
- Verify request JSON serialization shape

## Acceptance criteria
- [ ] `mise run build` passes
- [ ] SSE JSON → `ProviderEvent` parsing works for text, reasoning, and done events
- [ ] Request serialization produces valid JSON with correct fields
- [ ] Cancel closure from `InFlight` is wired through to `ResponseStream`
- [ ] Malformed SSE data surfaces as `JuliusError.responseParsingFailed`
