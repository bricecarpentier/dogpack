# 13 — Compaction

## Status: done

## Depends on
07 (Loop), 12 (Tools Management)

## Problem
Long conversations eventually exceed the model's context window. There is no mechanism to summarize or compress older turns, so agents hit token limits and fail mid-session.

## Scope
Add token usage tracking from provider responses, then use it to drive compaction — summarizing older conversation turns into a condensed form, keeping recent turns intact. This reduces context usage while preserving enough context for coherent continuation.

## Files
| File | Action |
|------|--------|
| `Sources/julius/Types.swift` | Modify — add `Usage` struct, `compactedSummary` case to `Message` |
| `Sources/julius/Session.swift` | Modify — add `replaceMessages` to `Session` protocol |
| `Sources/julius/Compaction.swift` | Create — `CompactionStrategy` protocol (split into `compactRange` + `generateSummary`), `Compactor`, default strategy |
| `Sources/julius/Loop.swift` | Modify — track usage from responses, accept optional `Compactor`, pass usage to compaction |
| `Sources/julius/OpenAI/OpenAIProvider.swift` | Modify — request `stream_options: {include_usage: true}`, parse `usage` from final chunk |
| `Tests/juliusTests/CompactionTests.swift` | Create — compaction strategy and Compactor tests |
| `Tests/juliusTests/IntegrationTests.swift` | Modify — add compaction integration test |

## Design

### What compaction does

When the conversation history grows too large, compaction replaces older messages with a summary produced by the model itself. The summary is injected as a special system-like message so the model retains key context without the full token cost.

### Architecture

```
Session messages: [user, assistant, user, assistant, user, assistant, ...]
                                              ↑ compaction threshold
Before compaction:  [m0, m1, m2, m3, m4, m5, m6, m7]
After compaction:   [summary(m0..m3), m4, m5, m6, m7]
```

### Cache-aware prompt structure

LLM APIs (Anthropic, OpenAI) cache prompt prefixes. If the system prompt or message ordering changes between turns, the cache breaks and every token must be re-processed. Compaction must preserve a stable cacheable prefix.

The prompt is structured as fixed layers:

```
┌──────────────────────────┐
│ System prompt            │  ← always present, stable, cached after turn 1
├──────────────────────────┤
│ Compaction summary       │  ← inserted at a fixed position, becomes part of cache
├──────────────────────────┤
│ Recent turns             │  ← grows each turn, not cached
└──────────────────────────┘
```

Rules:
- The system prompt never changes after session start.
- The compaction summary is always placed in the same position (right after system prompt, before recent turns). After the first post-compaction turn, the system prompt + summary form a new stable cache prefix.
- Compaction never restructures recent turns — only older turns are replaced.
- Multiple compactions append to or replace the previous summary, maintaining the fixed position.

### Token usage tracking

Provider responses include token counts. Currently, the `OpenAIProvider` discards this data. Usage tracking is needed for compaction and is generally useful for callers.

```swift
public struct Usage: Equatable, Sendable {
    public var promptTokens: Int
    public var completionTokens: Int
}
```

The `ProviderEvent` enum gains a case:

```swift
public enum ProviderEvent: Equatable, Sendable {
    case reasoningDelta(String)
    case textDelta(String)
    case toolCall(ToolCall)
    case done(StopReason)
    case usage(Usage)  // NEW — emitted once per response with final token counts
}
```

Providers parse usage from their streaming responses:
- **OpenAI:** Set `stream_options: {"include_usage": true}` in the request. The final streaming chunk contains a top-level `usage` object. Parse it and emit `.usage(Usage(...))`.
- **Anthropic:** The `message_start` event contains `usage.input_tokens`. The final `message_delta` contains `usage.output_tokens`. Combine and emit.

The `Loop` tracks the last received `Usage` and passes it to the `Compactor`.

### Compaction strategy

The strategy has two jobs: identify which messages are stale (pure) and generate a summary (I/O). These are separate methods so the Compactor can validate the range before spending tokens on an API call.

```swift
public protocol CompactionStrategy: Sendable {
    /// Returns the candidate range of messages to compact.
    /// Ranges should start and end on `.user` or `.compactedSummary`
    /// boundaries to preserve tool call/result pairs intact.
    /// The Compactor clamps out-of-bounds ranges but does not
    /// otherwise adjust them.
    func compactRange(in messages: [Message]) -> Range<Int>

    /// Generate a summary of the given messages using the provider.
    /// The default implementation appends a summarization user message
    /// to the conversation and sends it through the provider.
    /// Providers with dedicated compaction endpoints override this.
    func generateSummary(
        messages: [Message],
        provider: Provider,
        model: String
    ) async throws -> String
}
```

### Compactor

A `Compactor` type owns the compaction policy (threshold, strategy) and orchestrates the workflow in three phases:

1. **Range determination** (pure): calls `strategy.compactRange(in:)`, clamps to valid bounds, asserts boundary invariants in debug builds.
2. **Summary generation** (I/O): calls `strategy.generateSummary(...)` only if the range is non-empty.
3. **Application**: strips any prior `.compactedSummary`, inserts the new one, writes back via `replaceMessages`.

```swift
public struct Compactor: Sendable {
    var strategy: CompactionStrategy
    var tokenLimit: Int  // prompt token threshold (e.g. 80000 for a 128k context model)

    /// Check if compaction is needed based on the last usage and perform it.
    /// Returns true if compaction was performed.
    func compactIfNeeded(
        _ session: Session,
        lastUsage: Usage?,
        system: String,
        provider: Provider,
        model: String
    ) async throws -> Bool
}
```

The Compactor triggers when `lastUsage.promptTokens >= tokenLimit`. It enforces the message structure invariant: system prompt → at most one compaction summary → recent turns. Compaction is best-effort in the Loop — errors are caught and the conversation continues.

### Re-compaction

There is always at most one `.compactedSummary` in the message list. On re-compaction, the strategy receives the full message list including any existing summary. The existing summary is treated like any other old message — it gets folded into the new summary along with any other stale turns. The strategy does not special-case `.compactedSummary`.

```
First compaction:   [m0, m1, m2, m3, m4, m5] → [summary(m0..m1), m2, m3, m4, m5]
Re-compaction:      [summary(m0..m1), m2, m3, m4, m5, m6, m7] → [summary(m0..m3), m4, m5, m6, m7]
```

The summary always occupies the same slot. The Compactor strips any prior `.compactedSummary` before inserting the new one.

### Turn selection heuristic

A default strategy that keeps:
- The first user message (original task)
- The last N turns (configurable, default 4)
- Compacts everything in between into a summary

A "turn" is an atomic unit — `user` message plus the assistant response, including any tool call/result exchanges. The heuristic walks to the nearest `.user` message boundary so tool call/result pairs are never split.

The summary is generated by appending a summarization user message to the full conversation and sending it through the same provider. This reuses the cached prompt prefix — only the new user message and response tokens are uncached. The strategy then extracts the assistant response as the summary text.

### Boundary integrity

The strategy is responsible for producing ranges that start and end on `.user` or `.compactedSummary` boundaries. The Compactor clamps out-of-bounds ranges and asserts boundary invariants in debug builds. If a custom strategy violates the contract, the assertion fires immediately during development. There is no silent range adjustment in production — a bad range from a custom strategy is that strategy's bug to fix.

### New message type

```swift
public enum Message: Equatable, Sendable {
    case user(String)
    case assistant(AssistantMessage)
    case toolResult(ToolResult)
    case compactedSummary(String)  // NEW — summary of older turns
}
```

### Provider serialization of `.compactedSummary`

Each provider owns the mapping from `.compactedSummary` to its wire format. The `Compactor` guarantees exactly one summary at the right position in `[Message]`; each provider decides what that position means for its API.

**OpenAI:** Serializes `.compactedSummary` as a `{"role": "system"}` message in the messages array, placed after the system prompt message. OpenAI allows multiple system messages — both form the cached prefix.

**Anthropic:** Extracts `.compactedSummary` out of the messages array and appends it to the top-level `system` blocks. The summary never appears in the messages array. Both system blocks are cacheable.

**Fallback (no system role):** Serializes `.compactedSummary` as a user message with a delimiter prefix (e.g., `[Previous conversation summary]`). Functional but no special treatment by the model.

### Session change

The `Session` protocol gains one method — a store-level operation, not a policy decision:

```swift
public protocol Session: Sendable {
    func messages() async -> [Message]
    func append(_ message: Message) async throws
    func replaceMessages(_ messages: [Message]) async throws  // NEW
}
```

### Loop integration

The Loop receives an optional `Compactor`. It tracks the last `Usage` received from the provider. Before each request, it calls `compactor.compactIfNeeded(session, lastUsage:, system:, provider:, model:)` as best-effort — errors are caught and the conversation continues. If compaction succeeds, the session history is already updated and the Loop continues as normal.

If no compactor is provided, compaction is disabled. Usage is still tracked and surfaced regardless.

## Acceptance criteria
- [x] `Usage` struct with `promptTokens` and `completionTokens`
- [x] `ProviderEvent.usage(Usage)` case added and emitted by providers
- [x] OpenAI provider requests `stream_options: {include_usage: true}` and parses usage from final chunk
- [x] `CompactionStrategy` protocol split into `compactRange(in:)` (pure) and `generateSummary(...)` (I/O)
- [x] `Compactor` type with three-phase workflow: range → summary → apply
- [x] `Message.compactedSummary` case added and handled in all `switch` sites
- [x] Default strategy uses the provider to generate a summary of older turns
- [x] Loop tracks last `Usage`, accepts optional `Compactor`, passes usage to compaction
- [x] Compaction is best-effort in the Loop — errors are caught, conversation continues
- [x] Session gains `replaceMessages` method
- [x] Compactor enforces message structure invariant (system → summary → recent turns)
- [x] Compactor asserts boundary invariants in debug builds; strategies own boundary correctness
- [x] Empty range guard prevents wasted API calls
- [x] Empty summary guard prevents inserting useless `.compactedSummary("")`
- [x] Provider serializes `.compactedSummary` as a system-like message
- [x] Integration test: usage event parsing and compactedSummary serialization
- [x] All existing tests pass unchanged
