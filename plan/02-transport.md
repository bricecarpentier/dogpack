# 02 — Transport Protocol + HTTPTransport

## Status: not started

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

## Acceptance criteria
- [ ] `mise run build` passes
- [ ] SSE parsing handles multi-line events, `[DONE]`, and empty lines
- [ ] HTTPTransport connect/disconnect are no-ops
- [ ] MockTransport returns canned data for use in later units
- [ ] Network errors surface as `JuliusError`
