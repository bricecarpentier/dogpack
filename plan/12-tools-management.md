# 12 — Tools Management

## Status: not started

## Depends on
07 (Loop)

## Problem
julius has no tool support. The ReAct loop only handles text responses, tool-related enum cases are placeholder comments, and `OpenAIProvider` hardcodes `"tool_choice": "none"`. Agents cannot invoke tools through the library.

## Scope
Add dynamic tool management to julius: tool definition with JSON Schema, closure-based registry, provider serialization of tools in requests, SSE parsing of tool call events, and loop dispatch of tool calls with result collection.

## Files
| File | Action |
|------|--------|
| `Sources/julius/Types.swift` | Modify — add `ToolDefinition`, `ToolCall`, `ToolResult`; extend `ContentBlock`, `Message`, `StopReason`, `ProviderEvent`, `ProviderRequest` |
| `Sources/julius/ToolRegistry.swift` | Create — `ToolRegistry` protocol + `InMemoryToolRegistry` actor |
| `Sources/julius/OpenAI/OpenAIProvider.swift` | Modify — serialize `tools`/`tool_choice`, parse tool call SSE events |
| `Sources/julius/Loop.swift` | Modify — dispatch tool calls via registry, collect results, continue conversation |
| `Tests/juliusTests/ToolRegistryTests.swift` | Create — integration tests for tool dispatch |
| `Tests/juliusTests/OpenAIProviderTests.swift` | Modify — add tool serialization + parsing tests |

## Design

### 1. Types (`Types.swift`)

Tools are dynamic at the julius level — JSON Schema for input/output, raw string arguments, no Codable constraints. Type safety is a future agent-layer concern.

```swift
struct ToolDefinition: Sendable, Equatable {
    var name: String
    var description: String
    var inputSchema: JSONValue  // JSON Schema object
}

struct ToolCall: Sendable, Equatable {
    var id: String
    var name: String
    var arguments: String  // raw JSON string; models don't always produce valid JSON
}

struct ToolResult: Sendable, Equatable {
    var callId: String
    var output: String  // raw string; tool implementations decide format
}
```

Enum extensions:
- `ContentBlock.toolUse(ToolCall)`
- `Message.toolResult(ToolResult)`
- `StopReason.toolUse`
- `ProviderEvent.toolCallDelta(name: String, id: String, argumentsDelta: String)` — streamed deltas
- `ProviderEvent.toolCall(ToolCall)` — complete tool call (emitted after deltas accumulated)

`ProviderRequest` additions:
- `var tools: [ToolDefinition]?`
- `var toolChoice: ToolChoice?` where `enum ToolChoice { case auto, none, required, named(String) }`

### 2. Registry (`ToolRegistry.swift`)

```swift
typealias ToolHandler = @Sendable (String) async throws -> String
// Input: raw JSON arguments string. Output: raw result string.

protocol ToolRegistry: Sendable {
    func register(_ definition: ToolDefinition, handler: @escaping ToolHandler) async throws
    func definitions() async -> [ToolDefinition]
    func execute(_ call: ToolCall) async throws -> ToolResult
    func has(name: String) async -> Bool
}
```

`InMemoryToolRegistry` — actor-backed dictionary of `[String: (definition: ToolDefinition, handler: ToolHandler)]`.

Registration is additive. Overwriting an existing tool name throws. This keeps the registry predictable.

### 3. Provider Serialization (`OpenAIProvider.swift`)

When `ProviderRequest.tools` is non-empty:
- Serialize each `ToolDefinition` as OpenAI's `tools[]` format (`type: "function"`, `function: { name, description, parameters }`)
- Set `tool_choice` based on `ProviderRequest.toolChoice` (default: `auto`)

SSE parsing additions:
- Accumulate `function_call` deltas (index-based, same pattern as text/reasoning)
- Emit `ProviderEvent.toolCallDelta` during streaming
- Emit `ProviderEvent.toolCall(ToolCall)` when complete
- Set `StopReason.toolUse` when `finish_reason` is `"tool_calls"`

### 4. Loop Dispatch (`Loop.swift`)

The loop gains an optional `ToolRegistry`:

```swift
struct Loop: Sendable {
    // existing fields...
    var registry: (any ToolRegistry)?
}
```

Extended loop body:
1. **Existing**: build request, send, accumulate `AssistantMessage`
2. **New**: if `stopReason == .toolUse`:
   a. Extract `ToolCall`s from `AssistantMessage.content`
   b. Execute each via `registry.execute(call)` concurrently (with `TaskGroup`)
   c. Append `.assistant(msg)` to session
   d. Append each `.toolResult(result)` to session
   e. Loop again (next turn sees tool results in history)
3. If `registry` is nil and `stopReason == .toolUse`, throw — can't dispatch without a registry

This preserves the existing loop behavior when no registry is configured.

### 5. `accumulate()` helper

The existing `accumulate()` function (in `Loop.swift` or `Provider.swift`) must handle:
- Buffering `toolCallDelta` events into complete `ToolCall`s
- Adding them to `AssistantMessage.content` as `.toolUse(ToolCall)`

## Acceptance criteria
- [ ] `ToolDefinition`, `ToolCall`, `ToolResult` types with `Equatable`/`Sendable`
- [ ] `ContentBlock`, `Message`, `StopReason`, `ProviderEvent` extended with tool cases
- [ ] `ProviderRequest` accepts optional `tools` and `toolChoice`
- [ ] `ToolRegistry` protocol + `InMemoryToolRegistry` actor with register/definitions/execute
- [ ] `OpenAIProvider` serializes tools and parses tool call SSE events
- [ ] Loop dispatches tool calls when registry is present, throws when absent
- [ ] Integration test: register tool → loop triggers tool call → result fed back → final response
- [ ] Existing tests pass unchanged (no regressions)
