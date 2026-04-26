# 02 — Transport Protocol + HTTPTransport

## Status: done

## Depends on
01 (core types: `InFlight`, `JuliusError`)

## Scope
- Define `Transport` protocol
- Implement `HTTPTransport` with URLSession + SSE line parsing
- Create `MockTransport` shared test utility

## Files
| File | Action |
|------|--------|
| `Sources/julius/Transport.swift` | Create — `Transport` protocol |
| `Sources/julius/HTTPTransport.swift` | Create — URLSession SSE implementation |
| `Tests/juliusTests/HTTPTransportTests.swift` | Create |
| `Tests/juliusTests/Helpers/MockTransport.swift` | Create — shared mock |

## Transport protocol
```swift
protocol Transport: Sendable {
    func connect() async throws
    func send(_ data: Data) async throws -> InFlight
    func disconnect() async
}
```

## HTTPTransport behavior
- `connect()` / `disconnect()` — no-ops (HTTP is stateless)
- `send()` — POST request, reads SSE `data:` lines from response body
- Emits raw `Data` chunks (one per SSE event payload)
- Handles `data: [DONE]` as stream end
- All errors wrapped in `JuliusError`

## MockTransport behavior
- Accepts canned `Data` payload
- `connect()` / `disconnect()` — no-ops
- `send()` — returns canned data as single event, then finishes

## Implementation

### Test strategy
Integration-style tests exercising the full Transport → SSE parsing → InFlight path.

Uses `URLProtocol` subclass (Foundation built-in) to inject mock responses into URLSession — zero external dependencies, no real network.

HTTPTransport accepts a `URLSession` at init for testability.

1. **SSE parsing through HTTPTransport** — MockURLProtocol serves a realistic multi-event SSE payload (multi-line events, blank lines, `data: [DONE]`). Send request through HTTPTransport, collect all Data chunks from `InFlight.events`, verify each matches expected payload. Covers Transport protocol → URLSession → SSE line parsing → InFlight stream.

2. **Cancellation mid-stream** — MockURLProtocol serves SSE events with deliberate delay between chunks. Consume first chunk, call `InFlight.cancel`, verify stream terminates cleanly. Reuses `CancelTracker` actor pattern from Unit 01.

3. **Network and timeout failures map to JuliusError** — Parameterized over multiple `NSURLError` codes (`timedOut`, `notConnectedToInternet`, `cannotConnectToHost`). MockURLProtocol injects the error instantly (no real wait). Verify each surfaces through `InFlight.events` as `JuliusError.connectionFailed`.

4. **MockTransport contract** — Build MockTransport with canned data, call `send()`, verify it produces a well-formed `InFlight` with correct data and a working cancel closure. Validates the shared utility that Units 04-05 depend on.

### Acceptance criteria
- [ ] `mise run build` passes
- [ ] SSE parsing handles multi-line events, `[DONE]`, and empty lines
- [ ] HTTPTransport connect/disconnect are no-ops
- [ ] MockTransport returns canned data for use in later units
- [ ] Network errors surface as `JuliusError`
