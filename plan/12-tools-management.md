# 12 — Tools Management

## Status: done

## Depends on
07 (Loop)

## Problem
julius has no tool support. The loop only handles text responses, tool-related types don't exist, and `OpenAIProvider` hardcodes `"tool_choice": "none"`. Agents cannot invoke tools through the library.

## Scope
Add tool types, provider serialization of tool definitions in requests, SSE parsing of tool call events, loop support for surfacing tool calls to the caller, and basic CLI support for demonstrating the pipeline end-to-end.

Julius does **not** execute tools — that is an agent-layer concern. Julius provides the data pipeline: definitions -> request -> SSE -> tool calls -> results back into history.

## Files
| File | Action |
|------|--------|
| `Sources/julius/Types.swift` | Modify — add `ToolDefinition`, `ToolCall`, `ToolResult`, `ToolChoice`; extend `ContentBlock`, `Message`, `StopReason`, `ProviderEvent`, `ProviderRequest`, `LoopEvent` |
| `Sources/julius/OpenAI/OpenAIProvider.swift` | Modify — serialize `tools`/`tool_choice`, parse tool call SSE events |
| `Sources/julius/Loop.swift` | Modify — accept `tools` array, yield tool call events, complete on `.toolUse` |
| `Sources/dogpack/main.swift` | Modify — add built-in demo tools, handle tool call + result cycle in REPL |
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
- Loop: includes `tools` in requests, yields tool call events via `LoopEvent`, completes on `.toolUse`

**Agent (or CLI) owns:**
- Which tools to offer (passes `[ToolDefinition]` to the loop)
- Executing tool calls (extracted from the `LoopEvent` stream)
- Feeding results back (appends `.toolResult` to session, calls `loop.run()` again)
- Typed wrappers, approval gates, logging, retry logic

**Caller pattern:**
```swift
let tools: [ToolDefinition] = [weatherDef, searchDef]
let loop = Loop(provider: provider, session: session, model: "gpt-4o",
                maxTokens: 256, tools: tools)

while true {
    for try await event in loop.run() {
        switch event {
        case let .delta(.toolCall(call)):
            // Execute and append result
            let result = try await execute(call)
            try await session.append(.toolResult(result))
        case let .delta(.textDelta(text)):
            print(text, terminator: "")
        case let .complete(message):
            if message.stopReason == .stop { return message }
        default: break
        }
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

Update `LoopEvent` to carry tool call info:

```swift
public enum LoopEvent: Equatable, Sendable {
    case delta(ProviderEvent)
    case complete(AssistantMessage)
    case toolCalls([ToolCall])        // NEW — emitted when stopReason is .toolUse, before .complete
}
```

**Why this shape:**
- `ToolCall.arguments` is a raw `String` — models don't always produce valid JSON; tool implementations handle parsing (matches DESIGN.md decisions log).
- `ToolResult.output` is a raw `String` — tool implementations decide format.
- `ToolDefinition.inputSchema` uses the existing `JSONValue` type — no new dependencies, works with `JSONSerialization`.
- `ToolChoice` is its own enum — clean mapping to OpenAI's `tool_choice` field values.
- `ProviderEvent.toolCall(ToolCall)` only fires when complete — no partial tool calls leak to callers.
- `Message.toolResult(ToolResult)` is a top-level message case — tool results are sent as separate messages in the conversation (matches OpenAI's `role: "tool"` messages).
- `LoopEvent.toolCalls([ToolCall])` gives the caller all tool calls at once, extracted from `AssistantMessage.content`. The `.complete` event follows immediately after.

### Step 2 — OpenAI provider serialization (`Sources/julius/OpenAI/OpenAIProvider.swift`)

#### 2a. Request serialization — tools and tool_choice

Current code hardcodes:
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

#### 2b. Message serialization — tool results and tool calls

Current code handles `.user` and `.assistant`. Add `.toolResult`:

```swift
case let .toolResult(result):
    return [
        "role": "tool",
        "tool_call_id": result.callId,
        "content": result.output,
    ]
```

Extend `.assistant` to include `tool_calls` when content has `.toolUse` blocks:

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

#### 2c. SSE parsing — tool call events

OpenAI streams tool calls as delta chunks in `choices[].delta.tool_calls[]`:

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

Update `parseChunk` to accept `pendingToolCalls` inout parameter and handle tool call deltas:

```swift
private func parseChunk(
    _ data: Data,
    pendingToolCalls: inout [Int: (id: String, name: String, arguments: String)],
) throws -> [ProviderEvent] {
    // ... existing parsing (json, choices, delta) ...

    // After existing content/reasoning delta parsing:
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

### Step 3 — Loop changes (`Sources/julius/Loop.swift`)

#### 3a. Loop init — add tools parameter

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
        tools: [ToolDefinition]? = nil,          // NEW
        toolChoice: ToolChoice? = nil,           // NEW
    ) {
        // ... existing assignments ...
        self.tools = tools
        self.toolChoice = toolChoice
    }
}
```

#### 3b. Build request — include tools

In `buildRequest()`, pass tools into the request:

```swift
private func buildRequest() async throws -> ProviderRequest {
    let history = await session.messages()
    return ProviderRequest(
        model: model,
        system: system,
        messages: history,
        maxTokens: maxTokens,
        temperature: temperature,
        tools: tools,           // NEW
        toolChoice: toolChoice,  // NEW
    )
}
```

#### 3c. Process stream — handle tool call events

In `processStream()`, add handling for `.toolCall` provider events:

```swift
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
    continuation.yield(.delta(.toolCall(call)))
```

#### 3d. Loop body — yield toolCalls event and complete on .toolUse

In `run()`, after `session.append(.assistant(message))`, handle the `.toolUse` stop reason:

```swift
if message.stopReason == .toolUse {
    let calls = message.content.compactMap { block -> ToolCall? in
        if case let .toolUse(call) = block { return call }
        return nil
    }
    continuation.yield(.toolCalls(calls))
    continuation.yield(.complete(message))
    continuation.finish()
    return
}
```

The loop becomes:
1. Build request with tools -> send -> processStream (yields deltas including tool calls) -> append to session
2. If `.stop` -> yield `.complete`, finish
3. If `.toolUse` -> yield `.toolCalls` then `.complete`, finish
4. If `.length` -> loop (continuation)

The caller handles the tool execution + re-invocation cycle.

### Step 4 — CLI demo tools (`Sources/dogpack/main.swift`)

Add a small built-in tool set to demonstrate the pipeline. The CLI acts as the tool executor with hardcoded responses.

#### 4a. Built-in tool definitions

```swift
let builtinTools: [ToolDefinition] = [
    ToolDefinition(
        name: "get_weather",
        description: "Get the current weather for a city",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "city": .object([
                    "type": .string("string"),
                    "description": .string("City name"),
                ]),
            ]),
            "required": .array([.string("city")]),
        ]),
    ),
]
```

#### 4b. Built-in tool executor

```swift
func executeBuiltinTool(_ call: ToolCall) -> ToolResult {
    switch call.name {
    case "get_weather":
        return ToolResult(callId: call.id, output: "22°C, sunny")
    default:
        return ToolResult(callId: call.id, output: "Unknown tool")
    }
}
```

#### 4c. Display — handle tool calls in the stream

Extend `displayStream` to show tool calls and tool results:

```swift
case let .delta(.toolCall(call)):
    print("\n[tool call: \(call.name)(\(call.arguments))]")
```

#### 4d. REPL — tool execution loop

The REPL wraps the loop in an outer loop that handles tool call cycles:

```swift
// After consuming the stream, check if we need to execute tools
while true {
    var toolCalls: [ToolCall] = []
    var finalMessage: AssistantMessage?

    for try await event in loop.run() {
        switch event {
        case let .delta(.textDelta(text)):
            print(text, terminator: "")
            fflush(stdout)
        case let .delta(.reasoningDelta(text)):
            // ... existing reasoning display ...
        case let .delta(.toolCall(call)):
            print("\n[tool call: \(call.name)(\(call.arguments))]")
        case let .toolCalls(calls):
            toolCalls = calls
        case let .complete(message):
            finalMessage = message
        case .delta(.done):
            print()
        }
    }

    // If no tool calls, we're done
    guard !toolCalls.isEmpty else { break }

    // Execute and feed results back
    for call in toolCalls {
        let result = executeBuiltinTool(call)
        print("[tool result: \(result.output)]")
        try await session.append(.toolResult(result))
    }
}
```

### Step 5 — Tests

#### 5a. OpenAI provider tests

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

- Request with tools serializes tools[] and tool_choice correctly
- Multi-chunk tool call SSE -> ProviderEvent.toolCall -> ProviderEvent.done(.toolUse)
- Multiple concurrent tool calls via index field
- Tool result message serializes as role: "tool" with tool_call_id
- Assistant message with toolUse blocks serializes tool_calls array

#### 5b. Loop tests

New test cases:

- Loop with tools: provider returns toolUse -> loop yields .toolCalls then .complete
- Loop with tools, provider returns stop immediately -> normal stream (no regressions)
- Tool call events appear as .delta(.toolCall) during streaming

#### 5c. Integration tests

End-to-end test simulating the agent-side tool execution loop:
1. Create session, append user message
2. Create loop with tool definitions
3. Consume first stream -> get .toolCalls(get_weather) + .complete
4. Execute tool, append .toolResult to session
5. Consume second stream -> get text + .complete(.stop)
6. Verify session history: user, assistant(toolCall), toolResult, assistant(text)

### Implementation order

1. **Types.swift** — all new types and enum extensions. Every `switch` on `ContentBlock`, `Message`, `StopReason`, `ProviderEvent`, `LoopEvent` needs new cases. Audit all call sites:
   - `Loop.processStream()` — add `.toolCall` case
   - `OpenAIProvider.serializeMessage()` — add `.toolResult` case, extend `.assistant`
   - `OpenAIProvider.parseChunk()` — handle `"tool_calls"` finish reason
   - Test helpers that switch on `ProviderEvent` — add `.toolCall` case

2. **OpenAIProvider.swift** — serialization and parsing changes. Depends on step 1 types.

3. **Loop.swift** — tools parameter, yield `.toolCalls` + `.complete` on `.toolUse`. Depends on step 1.

4. **main.swift** — built-in tools, tool execution in REPL. Depends on steps 1-3.

5. **Tests** — can be written alongside each step. Run `mise run build` after each step. Run `mise run test` after step 4.

### Non-goals (deferred)

- Tool execution, registry, or handlers in julius — agent-layer concern
- Typed tool wrappers (Codable) — agent-layer concern
- Tool call streaming deltas as public events — internal only, emitted as complete `.toolCall`
- Tool approval/permission system — future feature
- Retry logic for failed tool calls — caller/agent responsibility
- Tool result content types (images, etc.) — raw string for now
- More than a trivial demo tool in the CLI — real tools are an agent concern

## Acceptance criteria
- [x] `ToolDefinition`, `ToolCall`, `ToolResult`, `ToolChoice` types with `Equatable`/`Sendable`
- [x] `ContentBlock.toolUse`, `Message.toolResult`, `StopReason.toolUse`, `ProviderEvent.toolCall`, `LoopEvent.toolCalls` added
- [x] `ProviderRequest` accepts optional `tools` and `toolChoice`
- [x] `OpenAIProvider` serializes tools, tool_choice, and tool result messages correctly
- [x] `OpenAIProvider` parses tool call SSE delta chunks into `.toolCall` events
- [x] `Loop` accepts optional `tools` and `toolChoice`, includes them in requests
- [x] `Loop` yields `.toolCalls` and `.complete` when `stopReason == .toolUse`
- [x] `processStream()` handles `.toolCall` events, flushing text/reasoning first
- [x] CLI demonstrates tool call cycle with built-in `get_weather` tool
- [x] All existing tests pass unchanged (no regressions)
- [x] New tests: provider serialization/parsing, loop tool behavior, integration cycle
