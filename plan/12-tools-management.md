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

Tools are dynamic at the julius level — JSON Schema for input definitions, raw string arguments and results. Type safety is a future agent-layer concern.

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

Note: `toolCallDelta` events are consumed internally by the provider's `mapToProviderEvents` and the `accumulate()` helper — they don't need to be a separate `ProviderEvent` case. The provider accumulates deltas internally and emits a single `.toolCall(ToolCall)` when the call is complete. This keeps the public API clean and matches how `.textDelta` / `.reasoningDelta` already work (callers buffer them).

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

New error case:

```swift
public enum JuliusError: Error, Sendable {
    case connectionFailed(String)
    case requestSerializationFailed(String)
    case responseParsingFailed(String)
    case transportDisconnected
    case cancelled
    case toolExecutionFailed(String)             // NEW
    case noRegistry                              // NEW
}
```

**Why this shape:**
- `ToolCall.arguments` is a raw `String` — models don't always produce valid JSON; tool implementations handle parsing (matches DESIGN.md decisions log).
- `ToolResult.output` is a raw `String` — tool implementations decide format.
- `ToolDefinition.inputSchema` uses the existing `JSONValue` type — no new dependencies, works with `JSONSerialization`.
- `ToolChoice` is its own enum — clean mapping to OpenAI's `tool_choice` field values.
- `ProviderEvent.toolCall(ToolCall)` only fires when complete — no partial tool calls leak to callers.
- `Message.toolResult(ToolResult)` is a top-level message case — tool results are sent as separate messages in the conversation (matches OpenAI's `role: "tool"` messages).

### Step 2 — Tool registry (`Sources/julius/ToolRegistry.swift`)

New file.

```swift
import Foundation

public typealias ToolHandler = @Sendable (String) async throws -> String

public protocol ToolRegistry: Sendable {
    func register(_ definition: ToolDefinition, handler: @escaping ToolHandler) async throws
    func definitions() async -> [ToolDefinition]
    func execute(_ call: ToolCall) async throws -> ToolResult
    func has(name: String) async -> Bool
}

public actor InMemoryToolRegistry: ToolRegistry {
    private var tools: [String: (definition: ToolDefinition, handler: ToolHandler)] = [:]

    public init() {}

    public func register(_ definition: ToolDefinition, handler: @escaping ToolHandler) throws {
        guard tools[definition.name] == nil else {
            throw JuliusError.requestSerializationFailed(
                "Tool '\(definition.name)' is already registered"
            )
        }
        tools[definition.name] = (definition: definition, handler: handler)
    }

    public func definitions() -> [ToolDefinition] {
        tools.values.map { $0.definition }
    }

    public func execute(_ call: ToolCall) async throws -> ToolResult {
        guard let entry = tools[call.name] else {
            throw JuliusError.toolExecutionFailed("Unknown tool: \(call.name)")
        }
        do {
            let output = try await entry.handler(call.arguments)
            return ToolResult(callId: call.id, output: output)
        } catch {
            throw JuliusError.toolExecutionFailed(
                "Tool '\(call.name)' failed: \(error.localizedDescription)"
            )
        }
    }

    public func has(name: String) -> Bool {
        tools[name] != nil
    }
}
```

**Design notes:**
- `register` throws on duplicate names — prevents accidental overwrite, keeps registry predictable.
- `execute` wraps handler errors in `JuliusError.toolExecutionFailed` — callers get a consistent error type regardless of what the handler throws.
- `definitions()` returns the list needed to populate `ProviderRequest.tools`.
- Actor isolation provides thread safety for concurrent register/execute.

### Step 3 — OpenAI provider serialization (`Sources/julius/OpenAI/OpenAIProvider.swift`)

#### 3a. `serializeRequest` — tools and tool_choice

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

#### 3b. `serializeMessage` — tool results

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

#### 3c. `parseChunk` — tool call SSE events

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

### Step 4 — Loop dispatch (`Sources/julius/Loop.swift`)

#### 4a. Add registry to Loop init

```swift
public struct Loop: Sendable {
    private let provider: Provider
    private let session: Session
    private let model: String
    private let system: String?
    private let maxTokens: Int
    private let temperature: Double?
    private let stopCondition: StopCondition
    private let registry: (any ToolRegistry)?   // NEW

    public init(
        provider: Provider,
        session: Session,
        model: String,
        system: String? = nil,
        maxTokens: Int,
        temperature: Double? = nil,
        stopCondition: @escaping StopCondition = { _ in false },
        registry: (any ToolRegistry)? = nil,    // NEW — default nil preserves existing behavior
    ) {
        // ... existing assignments ...
        self.registry = registry
    }
}
```

#### 4b. Pass tools from registry into ProviderRequest

After building the request, if registry is present, attach tool definitions:

```swift
var request = ProviderRequest(
    model: model,
    system: system,
    messages: history,
    maxTokens: maxTokens,
    temperature: temperature,
)

if let registry {
    let defs = await registry.definitions()
    if !defs.isEmpty {
        request.tools = defs
        request.toolChoice = .auto
    }
}
```

#### 4c. Handle `.toolUse` stop reason in loop body

After `session.append(.assistant(message))`, before the stop check:

```swift
if message.stopReason == .toolUse {
    guard let registry else {
        throw JuliusError.noRegistry
    }

    // Extract tool calls from content
    let toolCalls = message.content.compactMap { block -> ToolCall? in
        if case let .toolUse(call) = block { return call }
        return nil
    }

    // Execute all tool calls concurrently
    let results: [ToolResult] = try await withThrowingTaskGroup(of: ToolResult.self) { group in
        for call in toolCalls {
            group.addTask {
                try await registry.execute(call)
            }
        }
        var collected: [ToolResult] = []
        for try await result in group {
            collected.append(result)
        }
        return collected
    }

    // Append results to session (order matches tool calls)
    for result in results {
        try await session.append(.toolResult(result))
    }

    // Continue loop — next iteration sends tool results back to the model
    continue
}
```

The existing `if message.stopReason == .stop { return message }` remains unchanged — tool use `continue`s before reaching it.

#### 4d. Update `accumulate()` to handle tool calls

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

### Step 5 — Tests

#### 5a. `Tests/juliusTests/ToolRegistryTests.swift` (new file)

Tests for the registry itself:

```swift
@Suite("InMemoryToolRegistry tests")
struct ToolRegistryTests {
    // Register a tool, verify definitions() returns it
    @Test func `register and list definitions`() async throws

    // Register a tool, call execute with matching call, verify result
    @Test func `execute returns handler output`() async throws

    // Execute with unknown tool name throws toolExecutionFailed
    @Test func `execute unknown tool throws`() async

    // Registering same name twice throws
    @Test func `duplicate registration throws`() async throws

    // Register multiple tools, verify all returned
    @Test func `multiple tools registered`() async throws
}
```

#### 5b. `Tests/juliusTests/OpenAIProviderTests.swift` (extend)

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

#### 5c. `Tests/juliusTests/LoopTests.swift` (extend)

New test cases:

```swift
// Full tool loop: provider returns toolUse → registry executes → result appended →
// second turn returns stop → verify session history
@Test func `tool dispatch and continuation`() async throws

// Multiple tool calls in one response, all executed concurrently
@Test func `concurrent tool execution`() async throws

// toolUse stop reason without registry throws JuliusError.noRegistry
@Test func `tool use without registry throws`() async throws

// Tool handler throws → JuliusError.toolExecutionFailed propagates
@Test func `tool handler error propagation`() async throws
```

#### 5d. `Tests/juliusTests/IntegrationTests.swift` (extend)

```swift
// End-to-end: InMemorySession + InMemoryToolRegistry + OpenAIProvider (MockTransport) + Loop
// Simulate: user asks question → model calls get_weather tool → tool returns "22°C" →
// model uses result → final text answer
@Test func `full tool use cycle`() async throws
```

This test uses `SequencedMockProvider` (from LoopTests) with two canned sequences:
1. First: `.toolCall(get_weather)` + `.done(.toolUse)`
2. Second: `.textDelta("It's 22°C")` + `.done(.stop)`

### Implementation order

1. **Types.swift** — all new types and enum extensions. Existing code compiles because new fields are optional / new enum cases don't break existing switch exhaustiveness if defaults are used. But: every `switch` on `ContentBlock`, `Message`, `StopReason`, `ProviderEvent` needs new cases. Audit all call sites:
   - `Loop.accumulate()` — add `.toolCall` case
   - `OpenAIProvider.serializeMessage()` — add `.toolResult` case, extend `.assistant`
   - `OpenAIProvider.parseChunk()` — handle `"tool_calls"` finish reason
   - Test helper `accumulateMessage()` in TypesTests — add `.toolCall` case
   - Test helper `accumulate()` in IntegrationTests — add `.toolCall` case

2. **ToolRegistry.swift** — new file, no dependencies on changed code. Can be done in parallel with step 1.

3. **OpenAIProvider.swift** — serialization and parsing changes. Depends on step 1 types.

4. **Loop.swift** — registry integration and dispatch. Depends on steps 1 and 2.

5. **Tests** — can be written alongside each step. Run `mise run build` after each step to verify compilation. Run `mise run test` after step 4 to verify all tests.

### Non-goals (deferred)

- Typed tool wrappers (Codable) — agent-layer concern
- Tool call streaming deltas as public events — internal only, emitted as complete `.toolCall`
- Tool approval/permission system — future feature
- Retry logic for failed tool calls — caller/agent responsibility
- Tool result content types (images, etc.) — raw string for now

## Acceptance criteria
- [ ] `ToolDefinition`, `ToolCall`, `ToolResult`, `ToolChoice` types with `Equatable`/`Sendable`
- [ ] `ContentBlock.toolUse`, `Message.toolResult`, `StopReason.toolUse`, `ProviderEvent.toolCall` added
- [ ] `ProviderRequest` accepts optional `tools` and `toolChoice`
- [ ] `JuliusError.toolExecutionFailed` and `JuliusError.noRegistry` error cases
- [ ] `ToolRegistry` protocol + `InMemoryToolRegistry` actor with register/definitions/execute
- [ ] `OpenAIProvider` serializes tools, tool_choice, and tool result messages correctly
- [ ] `OpenAIProvider` parses tool call SSE delta chunks into `.toolCall` events
- [ ] `Loop` passes tool definitions from registry into requests
- [ ] `Loop` dispatches tool calls via registry, appends results, continues conversation
- [ ] `Loop` throws `JuliusError.noRegistry` when tool use requested without registry
- [ ] `accumulate()` handles `.toolCall` events, flushing text/reasoning first
- [ ] All existing tests pass unchanged (no regressions)
- [ ] New tests: registry, provider serialization/parsing, loop dispatch, integration cycle
