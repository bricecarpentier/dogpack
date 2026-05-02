# 13 — Compaction

## Status: not started

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
| `Sources/julius/Compaction.swift` | Create — `CompactionStrategy` protocol, `CompactionPlan`, `Compactor`, default strategy |
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

The strategy's only job is to identify which messages are stale and produce a summary. It does not decide the final message ordering — that belongs to the `Compactor`.

```swift
public protocol CompactionStrategy: Sendable {
    /// Identify stale messages and produce a summary of them.
    /// Returns the range of messages to compact and the summary text.
    func compact(
        messages: [Message],
        provider: Provider,
        model: String
    ) async throws -> CompactionPlan
}

public struct CompactionPlan: Equatable, Sendable {
    /// The range of messages to replace with the summary.
    public var compactRange: Range<Int>
    /// The summary text replacing the compacted messages.
    public var summary: String
}
```

### Compactor

A `Compactor` type owns the compaction policy (threshold, strategy) and orchestrates the workflow. It reads from the session, runs the strategy, and writes back. This keeps compaction logic out of both the Loop and the Session.

```swift
public struct Compactor: Sendable {
    var strategy: CompactionStrategy
    var tokenLimit: Int  // prompt token threshold (e.g. 80000 for a 128k context model)

    /// Check if compaction is needed based on the last usage and perform it.
    /// Returns true if compaction was performed.
    func compactIfNeeded(
        _ session: Session,
        lastUsage: Usage?,
        provider: Provider,
        model: String
    ) async throws -> Bool
}
```

The Compactor triggers when `lastUsage.promptTokens >= tokenLimit`. It enforces the message structure invariant: system prompt (if applicable) → at most one compaction summary → recent turns. It applies the `CompactionPlan` and writes the result back to the session via `replaceMessages`.

### Re-compaction

There is always at most one `.compactedSummary` in the message list. On re-compaction, the strategy receives the full message list including any existing summary. The existing summary is treated like any other old message — it gets folded into the new summary along with any other stale turns. The strategy does not special-case `.compactedSummary`.

```
First compaction:   [m0, m1, m2, m3, m4, m5] → [summary(m0..m1), m2, m3, m4, m5]
Re-compaction:      [summary(m0..m1), m2, m3, m4, m5, m6, m7] → [summary(m0..m3), m4, m5, m6, m7]
```

The summary always occupies the same slot. The `Compactor` enforces "at most one summary" as a post-condition.

### Turn selection heuristic

A default strategy that keeps:
- The first user message (original task)
- The last N turns (configurable, default 4)
- Compacts everything in between into a summary

A "turn" is an atomic unit — `user` message plus the assistant response, including any tool call/result exchanges. The heuristic must not split `assistant(.toolUse)` → `toolResult` pairs.

The summary is generated by sending the to-be-compacted messages to the model with a system prompt like: "Summarize the following conversation, preserving key decisions, findings, and the current state of work."

### Boundary integrity

When applying a `CompactionPlan`, the Compactor adjusts `compactRange` so it doesn't split a tool call/result pair. The strategy returns its best guess at a range; the Compactor walks the boundary forward or backward to the nearest safe split point (always on a `user` message boundary). This centralizes the integrity check and keeps strategies simple.

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

The Loop receives an optional `Compactor`. It tracks the last `Usage` received from the provider. Before each request, it calls `compactor.compactIfNeeded(session, lastUsage: lastUsage, provider, model)`. If compaction occurs, the session history is already updated — the Loop continues as normal.

If no compactor is provided, compaction is disabled. Usage is still tracked and surfaced regardless.

## Acceptance criteria
- [ ] `Usage` struct with `promptTokens` and `completionTokens`
- [ ] `ProviderEvent.usage(Usage)` case added and emitted by providers
- [ ] OpenAI provider requests `stream_options: {include_usage: true}` and parses usage from final chunk
- [ ] `CompactionStrategy` protocol with a default summarization implementation
- [ ] `CompactionPlan` type with `compactRange` and `summary`
- [ ] `Compactor` type that orchestrates strategy + token-based threshold + session writes
- [ ] `Message.compactedSummary` case added and handled in all `switch` sites
- [ ] Default strategy uses the provider to generate a summary of older turns
- [ ] Loop tracks last `Usage`, accepts optional `Compactor`, passes usage to compaction
- [ ] Session gains `replaceMessages` method
- [ ] Compactor enforces message structure invariant (system → summary → recent turns)
- [ ] Compactor adjusts compaction boundary to avoid splitting tool call/result pairs
- [ ] Provider serializes `.compactedSummary` as a system-like message
- [ ] Integration test: long conversation triggers compaction and continues successfully
- [ ] All existing tests pass unchanged
