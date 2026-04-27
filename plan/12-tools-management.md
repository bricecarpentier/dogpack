# 12 — Tools Management

## Status: not started

## Depends on
07 (Loop)

## Problem
julius has no tool support. The ReAct loop only handles text responses, tool-related enum cases are placeholder comments, and `OpenAIProvider` hardcodes `"tool_choice": "none"`. Agents cannot invoke tools through the library.

## Scope
Add tool types, provider serialization of tool definitions in requests, SSE parsing of tool call events, and loop support for surfacing tool calls to the caller. Julius does **not** execute tools — that is an agent-layer concern. Julius provides the data pipeline: definitions → request → SSE → tool calls → results back into history.

## Files
| File | Action |
|------|--------|
| `Sources/julius/Types.swift` | Modify — add `ToolDefinition`, `ToolCall`, `ToolResult`, `ToolChoice`; extend `ContentBlock`, `Message`, `StopReason`, `ProviderEvent`, `ProviderRequest` |
| `Sources/julius/OpenAI/OpenAIProvider.swift` | Modify — serialize `tools`/`tool_choice`, parse tool call SSE events |
| `Sources/julius/Loop.swift` | Modify — accept `tools` array, stop on `.toolUse` and return `AssistantMessage` |
| `Tests/juliusTests/OpenAIProviderTests.swift` | Modify — add tool serialization + parsing tests |
| `Tests/juliusTests/LoopTests.swift` | Modify — add tool-related loop tests |
| `Tests/juliusTests/IntegrationTests.swift` | Modify — add end-to-end tool cycle test |

## Design

### Architecture decision: julius surfaces, agent executes

Julius is a harness library for communicating with LLM providers. Tool execution is an agent-layer concern — the agent decides how to execute, whether to approve, how to handle errors, whether to retry.

**Julius owns:**
- Types: `ToolDefinition`, `ToolCall`, `ToolResult`, `ToolChoice`
- Provider serialization of tool definitions and tool results into requests
- SSE parsing of tool call deltas into complete `ToolCall` events
- Loop: includes `tools` in requests, stops on `.toolUse`, returns `AssistantMessage` with `ToolCall`s in `content`

**Agent owns:**
- Which tools to offer (passes `[ToolDefinition]` to the loop)
- Executing tool calls (extracted from `AssistantMessage.content`)
- Feeding results back (appends `.toolResult` to session, calls loop again)
- Typed wrappers, approval gates, logging, retry logic

**Caller pattern:**
```swift
let tools: [ToolDefinition] = [weatherDef, searchDef]
let loop = Loop(provider: provider, session: session, model: "gpt-4o",
                maxTokens: 256, tools: tools)

while true {
    let message = try await loop.run()
    if message.stopReason == .stop { return message }
    // Agent extracts and executes tool calls
    let calls = message.content.compactMap {
        if case .toolUse(let c) = $0 { return c } else { return nil }
    }
    for call in calls {
        let result = try await myAgentRegistry.execute(call)
        try await session.append(.toolResult(result))
    }
}
```

### Step 1 — Core types (`Sources/julius/Types.swift`)

Add to `// MARK: - Content` section:

```swift
public enum ContentBlock: Equatable, Sendable {
    case text(String)
    case reasoning(String)
    case toolUse(ToolCall)          // NEW
}
```

Add to `// MARK: - Messages` section:

```swift
public enum StopReason: Equatable, Sendable {
    case stop
    case length
    case contentFilter
    case toolUse                    // NEW
}

public enum Message: Equatable, Sendable {
    case user(String)
    case assistant(AssistantMessage)
    case toolResult(ToolResult)     // NEW
}
```

New types, add after `AssistantMessage`:

```swift
public struct ToolCall: Equatable, Sendable {
    public var id: String
    public var name: String
    public var arguments: String    // raw JSON string

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ToolResult: Equatable, Sendable {
    public var callId: String
    public var output: String       // raw string

    public init(callId: String, output: String) {
        self.callId = callId
        self.output = output
    }
}

public struct ToolDefinition: Equatable, Sendable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue   // JSON Schema object

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public enum ToolChoice: Equatable, Sendable {
    case auto
    case none
    case required
    case named(String)
}
```

Add to `// MARK: - Provider` section:

```swift
public enum ProviderEvent: Equatable, Sendable {
    case reasoningDelta(String)
    case textDelta(String)
    case toolCall(ToolCall)         // NEW — complete tool call after delta accumulation
    case done(StopReason)
}
```

Note: `toolCallDelta` events are consumed internally by the provider's `mapToProviderEvents` — they don't need to be a separate `ProviderEvent` case. The provider accumulates deltas internally and emits a single `.toolCall(ToolCall)` when the call is complete. This keeps the public API clean.

Extend `ProviderRequest`:

```swift
public struct ProviderRequest: Equatable {
    public var model: String
    public var system: String?
    public var messages: [Message]
    public var maxTokens: Int
    public var temperature: Double?
    public var tools: [ToolDefinition]?          // NEW
    public var toolChoice: ToolChoice?            // NEW
}
```

**Why this shape:**
- `ToolCall.arguments` is a raw `String` — models don't always produce valid JSON; tool implementations handle parsing (matches DESIGN.md decisions log).
- `ToolResult.output` is a raw `String` — tool implementations decide format.
- `ToolDefinition.inputSchema` uses the existing `JSONValue` type — no new dependencies, works with `JSONSerialization`.
- `ToolChoice` is its own enum — clean mapping to OpenAI's `tool_choice` field values.
- `ProviderEvent.toolCall(ToolCall)` only fires when complete — no partial tool calls leak to callers.
- `Message.toolResult(ToolResult)` is a top-level message case — tool results are sent as separate messages in the conversation (matches OpenAI's `role: "tool"` messages).

### Step 2 — OpenAI provider serialization (`Sources/julius/OpenAI/OpenAIProvider.swift`)

#### 2a. `serializeRequest` — tools and tool_choice

Current code (line ~82):
```swift
body["tool_choice"] = "none"
```

Replace with conditional logic:

```swift
if let tools = request.tools, !tools.isEmpty {
    body["tools"] = tools.map { tool in
        var function: [String: Any] = [
            "name": tool.name,
            "description": tool.description,
        ]
        function["parameters"] = jsonify(tool.inputSchema)
        return [
            "type": "function",
            "function": function,
        ]
    }
    body["tool_choice"] = serializeToolChoice(request.toolChoice ?? .auto)
} else {
    body["tool_choice"] = "none"
}
```

New helper to convert `ToolChoice` to JSON value:

```swift
private func serializeToolChoice(_ choice: ToolChoice) -> Any {
    switch choice {
    case .auto: return "auto"
    case .none: return "none"
    case .required: return "required"
    case .named(let name): return ["type": "function", "function": ["name": name]]
    }
}
```

New helper to convert `JSONValue` to `Any` for `JSONSerialization`:

```swift
private func jsonify(_ value: JSONValue) -> Any {
    switch value {
    case .null: return NSNull()
    case .bool(let b): return b
    case .int(let i): return i
    case .double(let d): return d
    case .string(let s): return s
    case .array(let a): return a.map(jsonify)
    case .object(let o): return o.mapValues(jsonify)
    }
}
```

#### 2b. `serializeMessage` — tool results

Current code (line ~96) handles `.user` and `.assistant`. Add `.toolResult`:

```swift
case let .toolResult(result):
    return [
        "role": "tool",
        "tool_call_id": result.callId,
        "content": result.output,
    ]
```

Also extend `.assistant` to include `tool_calls` when content has `.toolUse` blocks:

```swift
case let .assistant(msg):
    let text = msg.content.compactMap { block -> String? in
        if case let .text(text) = block { return text }
        return nil
    }.joined()

    let toolCalls = msg.content.compactMap { block -> [String: Any]? in
        if case let .toolUse(call) = block {
            return [
                "id": call.id,
                "type": "function",
                "function": [
                    "name": call.name,
                    "arguments": call.arguments,
                ],
            ]
        }
        return nil
    }

    var result: [String: Any] = ["role": "assistant"]
    if !text.isEmpty {
        result["content"] = text
    }
    if !toolCalls.isEmpty {
        result["tool_calls"] = toolCalls
    }
    return result
```

**Why:** OpenAI requires assistant messages with tool calls to include the `tool_calls` array, and tool results as `role: "tool"` messages with matching `tool_call_id`.

#### 2c. `parseChunk` — tool call SSE events

OpenAI streams tool calls as delta chunks in the `choices[].delta` object:

```json
{
  "choices": [{
    "index": 0,
    "delta": {
      "tool_calls": [{
        "index": 0,
        "id": "call_abc123",
        "type": "function",
        "function": { "name": "get_weather", "arguments": "{\"lo" }
      }]
    }
  }
}
```

Subsequent chunks have `function.arguments` fragments. The `id` and `function.name` appear only in the first chunk for each tool call.

`mapToProviderEvents` needs to accumulate tool call deltas. Add state to the parsing Task:

```swift
private func mapToProviderEvents(inFlight: InFlight) -> ResponseStream {
    let (stream, continuation) = AsyncThrowingStream<ProviderEvent, Error>.makeStream()

    let task = Task {
        // Accumulation state for in-flight tool calls
        var pendingToolCalls: [Int: (id: String, name: String, arguments: String)] = [:]

        do {
            for try await data in inFlight.events {
                let events = try parseChunk(data, pendingToolCalls: &pendingToolCalls)
                for event in events {
                    continuation.yield(event)
                }
            }

            // Flush any remaining tool calls when stream ends
            for (_, pending) in pendingToolCalls.sorted(by: { $0.key < $1.key }) {
                continuation.yield(.toolCall(ToolCall(
                    id: pending.id,
                    name: pending.name,
                    arguments: pending.arguments,
                )))
            }

            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    return ResponseStream(
        events: stream,
        cancel: { task.cancel(); await inFlight.cancel() },
    )
}
```

Update `parseChunk` signature and add tool call delta parsing:

```swift
private func parseChunk(
    _ data: Data,
    pendingToolCalls: inout [Int: (id: String, name: String, arguments: String)],
) throws -> [ProviderEvent] {
    // ... existing parsing (json, choices, delta) ...

    // After existing content/reasoning delta parsing, add:
    if let toolCallDeltas = delta["tool_calls"] as? [[String: Any]] {
        for tcDelta in toolCallDeltas {
            guard let index = tcDelta["index"] as? Int else { continue }

            var pending = pendingToolCalls[index] ?? (id: "", name: "", arguments: "")

            if let id = tcDelta["id"] as? String { pending.id = id }
            if let function = tcDelta["function"] as? [String: Any] {
                if let name = function["name"] as? String { pending.name = name }
                if let args = function["arguments"] as? String { pending.arguments += args }
            }

            pendingToolCalls[index] = pending
        }
    }

    // Update finish_reason handling:
    if let finishReason = choice["finish_reason"] as? String {
        switch finishReason {
        case "stop": events.append(.done(.stop))
        case "length": events.append(.done(.length))
        case "content_filter": events.append(.done(.contentFilter))
        case "tool_calls":
            // Emit completed tool calls before done event
            for (_, pending) in pendingToolCalls.sorted(by: { $0.key < $1.key }) {
                events.append(.toolCall(ToolCall(
                    id: pending.id,
                    name: pending.name,
                    arguments: pending.arguments,
                )))
            }
            pendingToolCalls.removeAll()
            events.append(.done(.toolUse))
        default: events.append(.done(.stop))
        }
    }

    return events
}
```

**Important:** `pendingToolCalls` is local to the `mapToProviderEvents` Task — no mutable state leaks outside. The method signature changes from `parseChunk(_:)` to `parseChunk(_:pendingToolCalls:)` with an `inout` parameter.

**Edge case — multiple tool calls in one response:** OpenAI uses the `index` field to distinguish concurrent tool calls. The dictionary accumulation handles this naturally.

### Step 3 — Loop changes (`Sources/julius/Loop.swift`)

#### 3a. Add `tools` to Loop init

```swift
public struct Loop: Sendable {
    private let provider: Provider
    private let session: Session
    private let model: String
    private let system: String?
    private let maxTokens: Int
    private let temperature: Double?
    private let stopCondition: StopCondition
    private let tools: [ToolDefinition]?        // NEW
    private let toolChoice: ToolChoice?          // NEW

    public init(
        provider: Provider,
        session: Session,
        model: String,
        system: String? = nil,
        maxTokens: Int,
        temperature: Double? = nil,
        stopCondition: @escaping StopCondition = { _ in false },
        tools: [ToolDefinition]? = nil,          // NEW — default nil preserves existing behavior
        toolChoice: ToolChoice? = nil,           // NEW
    ) {
        // ... existing assignments ...
        self.tools = tools
        self.toolChoice = toolChoice
    }
}
```

#### 3b. Include tools in ProviderRequest

In `run()`, pass tools into the request:

```swift
let request = ProviderRequest(
    model: model,
    system: system,
    messages: history,
    maxTokens: maxTokens,
    temperature: temperature,
    tools: tools,           // NEW
    toolChoice: toolChoice,  // NEW
)
```

#### 3c. Return on `.toolUse` instead of looping

The loop currently only returns on `.stop`. After the existing stop check, add:

```swift
if message.stopReason == .toolUse {
    return message    // Surface to caller — agent handles execution
}
```

The existing `if message.stopReason == .stop { return message }` and `.length` continuation remain unchanged. The loop becomes:

1. Build request with tools → send → accumulate → append to session
2. If `.stop` → return (done)
3. If `.toolUse` → return (caller executes tools, appends results, calls `run()` again)
4. If `.length` → loop (continuation)

#### 3d. Update `accumulate()` to handle tool calls

The `accumulate()` method already iterates `ProviderEvent`s. Add a case for `.toolCall`:

```swift
private func accumulate(_ responseStream: ResponseStream) async throws -> AssistantMessage {
    var contentBlocks: [ContentBlock] = []
    var currentText = ""
    var currentReasoning = ""
    var stopReason: StopReason = .stop

    for try await event in responseStream.events {
        switch event {
        case let .textDelta(text):
            currentText += text
        case let .reasoningDelta(text):
            currentReasoning += text
        case let .toolCall(call):
            // Flush any pending text/reasoning before tool call
            if !currentReasoning.isEmpty {
                contentBlocks.append(.reasoning(currentReasoning))
                currentReasoning = ""
            }
            if !currentText.isEmpty {
                contentBlocks.append(.text(currentText))
                currentText = ""
            }
            contentBlocks.append(.toolUse(call))
        case let .done(reason):
            if !currentReasoning.isEmpty {
                contentBlocks.append(.reasoning(currentReasoning))
                currentReasoning = ""
            }
            if !currentText.isEmpty {
                contentBlocks.append(.text(currentText))
                currentText = ""
            }
            stopReason = reason
        }
    }

    return AssistantMessage(content: contentBlocks, stopReason: stopReason)
}
```

**Event ordering guarantee:** The provider emits `.toolCall(ToolCall)` events before `.done(.toolUse)`, so `accumulate()` always sees complete tool calls before the stop reason.

### Step 4 — Tests

#### 4a. `Tests/juliusTests/OpenAIProviderTests.swift` (extend)

Add SSE chunk helper for tool call deltas:

```swift
private func toolCallChunk(
    index: Int = 0,
    callIndex: Int = 0,
    id: String? = nil,
    name: String? = nil,
    arguments: String? = nil,
    finishReason: String? = nil,
) -> Data
```

New test cases:

```swift
// Request with tools serializes tools[] and tool_choice correctly
@Test func `request with tools serializes correctly`() async throws

// Multi-chunk tool call SSE → ProviderEvent.toolCall → ProviderEvent.done(.toolUse)
@Test func `tool call sse parsing`() async throws

// Multiple concurrent tool calls via index field
@Test func `multiple tool calls in one response`() async throws

// Tool result message serializes as role: "tool" with tool_call_id
@Test func `tool result message serialization`() async throws

// Assistant message with toolUse blocks serializes tool_calls array
@Test func `assistant with tool calls serialization`() async throws
```

#### 4b. `Tests/juliusTests/LoopTests.swift` (extend)

New test cases:

```swift
// Loop with tools: provider returns toolUse → loop returns AssistantMessage with ToolCalls
@Test func `tool use returns message with calls`() async throws

// Loop without tools: still works exactly as before (no regressions)
// (existing tests cover this)

// Loop with tools, provider returns stop immediately → normal return
@Test func `tools present but no tool call`() async throws
```

#### 4c. `Tests/juliusTests/IntegrationTests.swift` (extend)

```swift
// End-to-end: InMemorySession + OpenAIProvider (MockTransport) + Loop
// Simulate: user asks question → model calls get_weather tool → loop returns →
// caller executes tool, appends result → loop.run() again → model uses result → final answer
@Test func `full tool use cycle`() async throws
```

This test simulates the agent-side tool execution loop:
1. Create session, append user message
2. Create loop with tool definitions
3. First `run()` → provider returns `.toolCall(get_weather)` + `.done(.toolUse)`
4. Extract tool calls, "execute" them (hardcoded result), append `.toolResult`
5. Second `run()` → provider returns text + `.done(.stop)`
6. Verify session history: user, assistant(toolCall), toolResult, assistant(text)

### Implementation order

1. **Types.swift** — all new types and enum extensions. Every `switch` on `ContentBlock`, `Message`, `StopReason`, `ProviderEvent` needs new cases. Audit all call sites:
   - `Loop.accumulate()` — add `.toolCall` case
   - `OpenAIProvider.serializeMessage()` — add `.toolResult` case, extend `.assistant`
   - `OpenAIProvider.parseChunk()` — handle `"tool_calls"` finish reason
   - Test helper `accumulateMessage()` in TypesTests — add `.toolCall` case
   - Test helper `accumulate()` in IntegrationTests — add `.toolCall` case

2. **OpenAIProvider.swift** — serialization and parsing changes. Depends on step 1 types.

3. **Loop.swift** — tools parameter, return on `.toolUse`. Depends on step 1.

4. **Tests** — can be written alongside each step. Run `mise run build` after each step to verify compilation. Run `mise run test` after step 3 to verify all tests.

### Non-goals (deferred)

- Tool execution, registry, or handlers — agent-layer concern
- Typed tool wrappers (Codable) — agent-layer concern
- Tool call streaming deltas as public events — internal only, emitted as complete `.toolCall`
- Tool approval/permission system — future feature
- Retry logic for failed tool calls — caller/agent responsibility
- Tool result content types (images, etc.) — raw string for now

## Acceptance criteria
- [ ] `ToolDefinition`, `ToolCall`, `ToolResult`, `ToolChoice` types with `Equatable`/`Sendable`
- [ ] `ContentBlock.toolUse`, `Message.toolResult`, `StopReason.toolUse`, `ProviderEvent.toolCall` added
- [ ] `ProviderRequest` accepts optional `tools` and `toolChoice`
- [ ] `OpenAIProvider` serializes tools, tool_choice, and tool result messages correctly
- [ ] `OpenAIProvider` parses tool call SSE delta chunks into `.toolCall` events
- [ ] `Loop` accepts optional `tools` and `toolChoice`, includes them in requests
- [ ] `Loop` returns `AssistantMessage` with `ToolCall`s in content when `stopReason == .toolUse`
- [ ] `accumulate()` handles `.toolCall` events, flushing text/reasoning first
- [ ] All existing tests pass unchanged (no regressions)
- [ ] New tests: provider serialization/parsing, loop tool behavior, integration cycle
