# 03 — Session Protocol + InMemorySession

## Status: not started

## Depends on
01 (core types: `Message`, `AssistantMessage`)

## Scope
- Define `Session` protocol
- Implement `InMemorySession` as an actor

## Files
| File | Action |
|------|--------|
| `Sources/julius/Session.swift` | Create — `Session` protocol |
| `Sources/julius/InMemorySession.swift` | Create — actor-backed in-memory store |
| `Tests/juliusTests/InMemorySessionTests.swift` | Create |

## Session protocol
```swift
protocol Session: Sendable {
    func messages() async -> [Message]
    func append(_ message: Message) async throws
}
```

## InMemorySession behavior
- Actor for thread safety
- Internal `[Message]` array
- `messages()` returns a copy
- `append()` appends to array

## Acceptance criteria
- [ ] `mise run build` passes
- [ ] Empty session returns `[]`
- [ ] Appended messages are returned in order
- [ ] Concurrent append/read is safe (actor isolation)
