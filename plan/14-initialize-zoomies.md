# 14 — Initialize Zoomies (Agent)

## Status: not started

## Depends on
12 (Tools Management)

## Problem
julius is a harness library — it handles transport, sessions, streaming, and tool pipelines. Concrete tool implementations (bash, file editing, programmatic calling) are agent-layer concerns. There is no agent package that uses julius to build an actual agent.

## Scope
Create the `zoomies` Swift package as a separate module in the Dogpack repository. Zoomies depends on julius and provides the agent runtime: tool registry, tool execution loop, and a foundation for adding concrete tools and skills in subsequent plans.

Note: Plan 18 introduces `tricks` as a standalone library and adds it as a dependency of zoomies. This plan sets up zoomies without tricks; plan 18 extends the dependency and adds `SkillConfig` support to the Agent.

## Files
| File | Action |
|------|--------|
| `Package.swift` | Modify — add `zoomies` library product and target |
| `Sources/julius/Loop.swift` | Modify — `tools` parameter `[ToolDefinition]?` → `[ToolDefinition]` |
| `Sources/julius/Types.swift` | Modify — `ProviderRequest.tools` `[ToolDefinition]?` → `[ToolDefinition]` |
| `Sources/zoomies/AgentEvent.swift` | Create — streaming events emitted by the agent turn loop |
| `Sources/zoomies/ToolRegistry.swift` | Create — register and dispatch tool implementations |
| `Sources/zoomies/Agent.swift` | Create — agent runtime: owns loop, session, tools, executes turns |
| `Sources/zoomies/ToolProtocol.swift` | Create — `Tool` protocol that concrete tools conform to |
| `Sources/dogpack/WeatherTool.swift` | Create — `WeatherTool: Tool` wrapping existing get_weather logic |
| `Sources/dogpack/main.swift` | Modify — use `Agent` + `ToolRegistry` instead of manual loop |
| `Tests/zoomiesTests/AgentTests.swift` | Create — agent turn execution tests |
| `Tests/zoomiesTests/ToolRegistryTests.swift` | Create — tool registration and dispatch tests |

## Design

### Package structure

```
Dogpack/
├── Sources/
│   ├── julius/          # Harness (existing)
│   ├── zoomies/         # Agent (new)
│   └── dogpack/         # CLI (existing)
├── Tests/
│   ├── juliusTests/
│   ├── zoomiesTests/    # New
│   └── dogpackTests/
└── Package.swift
```

Plan 18 adds `tricks` and `tricksTests` directories, and extends the zoomies dependency to include tricks.

### Package.swift changes

```swift
products: [
    .library(name: "julius", targets: ["julius"]),
    .library(name: "zoomies", targets: ["zoomies"]),  // NEW
],
targets: [
    // ... existing targets ...
    .target(name: "zoomies", dependencies: ["julius"]),                    // NEW
    .testTarget(name: "zoomiesTests", dependencies: ["zoomies"]),          // NEW
    // MODIFIED — dogpack now depends on zoomies
    .executableTarget(name: "dogpack", dependencies: [
        "zoomies",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
    ]),
]
```

Plan 18 extends this to add `tricks` as a product and `["julius", "tricks"]` as zoomies' dependencies.

### CLI integration

The CLI (`dogpack`) is the first consumer of zoomies. The existing `get_weather` tool is refactored into `WeatherTool: Tool`, and the hand-rolled loop in `main.swift` is replaced by `Agent` + `ToolRegistry`:

- `WeatherTool` wraps the existing `builtinTools` definition and `executeBuiltinTool` logic
- `main.swift` constructs a `ToolRegistry`, registers `WeatherTool`, and uses `Agent.runTurn` to handle REPL input
- The manual `handleToolCycle` loop and `printEvent` logic are replaced by iterating `AgentEvent`s from `runTurn`

This validates the zoomies API end-to-end and removes duplicated agent-loop logic from the CLI.

### Tool protocol

```swift
import julius

/// A tool that the agent can offer to the LLM and execute on its behalf.
public protocol Tool: Sendable {
    /// The tool definition sent to the LLM in the request.
    var definition: ToolDefinition { get }

    /// Execute a tool call and return the result.
    func execute(_ call: ToolCall) async throws -> ToolResult
}
```

Concrete tools (bash, text editor, etc.) conform to this protocol. Each tool owns its definition schema and execution logic.

### ToolRegistry

```swift
/// Registers tools and dispatches incoming tool calls to the right implementation.
/// Uses an actor to provide safe concurrency under Swift strict concurrency checking.
public actor ToolRegistry {
    private var tools: [String: any Tool] = [:]

    public init() {}

    /// Register a tool. Its name must be unique.
    public func register(_ tool: any Tool) throws

    /// All registered tool definitions (for including in Loop requests).
    /// Returns definitions sorted alphabetically by name (see cache-aware ordering below).
    public var definitions: [ToolDefinition]

    /// Dispatch a tool call to the registered implementation.
    public func execute(_ call: ToolCall) async throws -> ToolResult
}
```

The registry maps tool names to implementations. When the loop yields `.toolCalls`, the agent looks up each call by name and dispatches it. Using `actor` rather than `final class` ensures safe mutation under Swift strict concurrency — matches the same pattern used by `InMemorySession` in julius.

### Cache-aware tool ordering

LLM APIs cache the request prefix, including the `tools` block. If tool definitions appear in a different order between requests, the cache breaks. `definitions` must return tools in a **deterministic, stable order** — sorted alphabetically by name. This ensures the serialized `tools` array is byte-identical across turns, maximizing cache hits.

### Non-optional tools in julius

The `tools` parameter in julius is `[ToolDefinition]?`, conflating two meanings: "no tools registered" vs "tools concept not applicable." This plan refactors it to `[ToolDefinition]` (never nil). The distinction between including or omitting the `tools` key in the API request is a provider serialization concern, not an Agent or Loop concern. Changes:

- `Loop.init(tools:)` — `[ToolDefinition]?` → `[ToolDefinition]`
- `ProviderRequest.tools` — `[ToolDefinition]?` → `[ToolDefinition]`
- OpenAI serialization: omit the `tools` key when the array is empty

### Agent events

The agent streams events during a turn, consistent with julius's streaming-first design. This allows callers to display text deltas in real-time, show tool activity, or collect the final result.

```swift
/// Events emitted by the agent during a turn.
public enum AgentEvent: Sendable {
    case textDelta(String)
    case reasoningDelta(String)
    case toolCalls([ToolCall])
    case toolResult(ToolResult)
    case complete(AssistantMessage)
}
```

### Agent

```swift
/// The agent runtime. Owns a julius Loop, Session, and ToolRegistry.
/// Runs turns, dispatches tool calls, feeds results back.
public final class Agent: Sendable {
    private let provider: Provider
    private let session: Session
    private let registry: ToolRegistry
    private let model: String
    private let system: String?
    private let maxTokens: Int

    public init(
        provider: Provider,
        session: Session,
        registry: ToolRegistry,
        model: String,
        system: String? = nil,
        maxTokens: Int = 4096
    )

    /// Run a single user turn through the loop, executing any tool calls.
    /// Streams agent events — text/reasoning deltas, tool calls, results, and the final message.
    public func runTurn(_ userMessage: String) -> AsyncThrowingStream<AgentEvent, Error>
}
```

The `system` parameter holds the composed system prompt. Plan 18's `SkillComposer` builds it from base instructions + skill instructions and passes it to the Agent init. This keeps the system prompt stable across the session (set once at init, never changed).

The agent's `runTurn`:
1. Appends the user message to the session
2. Creates a Loop with the registry's tool definitions
3. Streams events from the loop, forwarding deltas to the caller
4. On `.toolCalls`: executes tool calls via the registry, yields `.toolResult` events, feeds results back to the session
5. Loops until the model returns `.stop` (no more tool calls)
6. Yields `.complete` with the final assistant message

A max iterations cap (e.g., limiting tool rounds per turn) is deferred to a future plan.

### Turn execution flow

```
User message
     │
     ▼
Agent.runTurn(message) → AsyncThrowingStream<AgentEvent, Error>
     │
     ├─ session.append(.user(message))
     ├─ Loop(provider, session, tools: registry.definitions)
     │
     ▼
Loop.run()
     │
     ├─ yields .delta(.textDelta(text))      → yield .textDelta(text)
     ├─ yields .delta(.reasoningDelta(text)) → yield .reasoningDelta(text)
     │
     ├─ yields .toolCalls([call1, call2]) + .complete(_)
     │       │
     │       ▼
     │   yield .toolCalls([call1, call2])
     │       │
     │       ▼
     │   registry.execute(call1), registry.execute(call2)
     │       │
     │       ▼
     │   yield .toolResult(result1), yield .toolResult(result2)
     │       │
     │       ▼
     │   session.append(.toolResult(result1))
     │   session.append(.toolResult(result2))
     │       │
     │       ▼
     │   Loop.run() again (inner loop)
     │
     └─ yields .complete(message) with .stop → yield .complete(message), finish
```

### No tools yet

This plan sets up the agent skeleton. Concrete tools (bash, text editor, Lua) come in plans 15, 16, 17. The agent works without tools too — just text in, text out.

## Acceptance criteria
- [ ] julius `tools` parameter refactored from `[ToolDefinition]?` to `[ToolDefinition]` in `Loop` and `ProviderRequest`
- [ ] OpenAI serialization omits `tools` key when array is empty
- [ ] All existing julius tests pass after refactor
- [ ] `zoomies` target compiles as a library depending on `julius`
- [ ] `zoomiesTests` target compiles and runs
- [ ] `Tool` protocol with `definition` and `execute(_:)` requirements
- [ ] `ToolRegistry` registers tools, lists definitions, dispatches calls
- [ ] `AgentEvent` enum with `textDelta`, `reasoningDelta`, `toolCalls`, `toolResult`, `complete` cases
- [ ] `Agent.runTurn` streams `AgentEvent`s (text/reasoning deltas forwarded in real-time)
- [ ] `Agent` runs a text-only turn (no tools) end-to-end, streaming deltas and yielding `.complete`
- [ ] `Agent` runs a turn with a mock tool: LLM calls tool, agent executes, yields `.toolCalls` and `.toolResult` events, feeds result, gets final response
- [ ] CLI refactored to use `Agent` + `ToolRegistry` with `WeatherTool: Tool`
- [ ] `WeatherTool` wraps existing `get_weather` definition and execution logic
- [ ] CLI REPL streams `AgentEvent`s (text deltas, tool activity) instead of manual loop
