# 01 — Core Types + Package Setup

## Status: done

## Depends on
Nothing.

## Scope
- Add `julius` library target to `Package.swift`
- Add `juliusTests` test target to `Package.swift`
- Define all core types in `Sources/julius/Types.swift`

## Files
| File | Action |
|------|--------|
| `Package.swift` | Modify — add library + test targets |
| `Sources/julius/Types.swift` | Create |
| `Tests/juliusTests/TypesTests.swift` | Create |

## Types to define
- `JSONValue` — recursive enum (null, bool, int, double, string, array, object)
- `ContentBlock` — enum (text, reasoning)
- `StopReason` — enum (stop, length, contentFilter)
- `Message` — enum (user, assistant)
- `AssistantMessage` — struct with `[ContentBlock]` and `StopReason`
- `ProviderEvent` — enum (reasoningDelta, textDelta, done)
- `ProviderRequest` — struct (model, system, messages, maxTokens, temperature)
- `ResponseStream` — struct with event stream + cancel closure
- `InFlight` — struct with data stream + cancel closure
- `JuliusError` — enum (connectionFailed, requestSerializationFailed, responseParsingFailed, transportDisconnected)

## Implementation

### Test strategy
Integration-style tests exercising types together in realistic workflows.

1. **Full turn accumulation** — build conversation history end-to-end: user message → ProviderRequest → fake ProviderEvent stream → accumulate into AssistantMessage → append to array → verify full history. Exercises ~8 types in one pass.

2. **Streaming with cancellation** — build an InFlight/ResponseStream, consume partial events, call cancel, verify stream terminates. Tests closure+stream wiring.

3. **JSONValue for realistic payloads** — construct a JSONValue tree matching an actual API response shape, extract nested values. Proves the recursive enum works for real data.

4. **Error propagation through streams** — build an InFlight/ResponseStream that throws, verify the error propagates through iteration. Tests the failure path through the same stream wiring.

### Acceptance criteria
- [ ] `mise run build` passes
- [ ] All types are `Sendable`
- [ ] Three integration-style tests pass
