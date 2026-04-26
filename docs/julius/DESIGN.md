# Julius — LLM Harness Library

Julius is a zero-dependency Swift library for communicating with LLM providers, built as part of the Dogpack project.

## Design Principles

- **Zero external dependencies** — no third-party packages
- **Swift native concurrency** — async/await, actors, AsyncThrowingStream
- **macOS 13+** target platform
- **Swift Testing framework** (not XCTest)
- **Testable at every layer** via protocol-based mocking

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  Caller (e.g. Agent loop)                                           │
│                                                                     │
│  1. Get history from Session                                        │
│  2. Build ProviderRequest                                           │
│  3. Call provider.send(request)                                     │
│  4. Accumulate ProviderEvents into AssistantMessage                 │
│  5. Append AssistantMessage to Session                              │
└──────────┬──────────────────────┬──────────────────────┬────────────┘
           │                      │                      │
           ▼                      ▼                      ▼
   ┌──────────────┐      ┌──────────────┐      ┌──────────────┐
   │   Session    │      │   Provider   │      │   Transport  │
   │  (protocol)  │      │  (protocol)  │      │  (protocol)  │
   │              │      │              │      │              │
   │ messages()   │      │ send(req) -> │      │ send(data)-> │
   │ append(msg)  │      │ ResponseStrm │      │ InFlight     │
   │              │      │              │      │              │
   └──────────────┘      └──────┬───────┘      └──────┬───────┘
          ▲                     │                     │
          │              ┌──────┴─────────┐    ┌──────┴───────┐
          │              │                │    │              │
          │              │ OpenAIProvider │    │ HTTPTransport│
          │              │                │    │              │
          │              │ - serialize    │    │ - URLSession │
          │              │   request      │    │ - SSE parse  │
          │              │ - parse SSE    │    │              │
          │              │   into         │    └──────────────┘
          │              │   ProviderEvt  │
          │              │                │
          │              └────────────────┘
          │
    ┌─────┴──────┐
    │            │
    │ InMemory   │ FileSystem  SQLite   ...
    │ Session    │ Session     Session
    │            │
    └────────────┘
```

### Data Flow (single turn)

```
Session.messages() --> build ProviderRequest --> Provider.send()
                                                    |
                       serialize to JSON <----------+
                              |
                       Transport.send(json) --> HTTP/SSE --> API
                              |
                       InFlight.events <---------- SSE response
                              |
                       Provider parses:
                         raw Data
                           -> ProviderEvent.{reasoningDelta, textDelta, done}
                              |
                       Caller accumulates into AssistantMessage
                              |
                       Session.append(.assistant(msg)) --> stored
```

## Core Types

### JSON

```swift
enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}
```

### Transport

```swift
struct InFlight: Sendable {
    let events: AsyncThrowingStream<Data, Error>
    let cancel: @Sendable () async -> Void
}

protocol Transport: Sendable {
    func connect() async throws
    func send(_ data: Data) async throws -> InFlight
    func disconnect() async
}
```

- **Single Transport protocol** — HTTPTransport fakes persistence (connect/disconnect are no-ops)
- **InFlight** returns both an event stream and a cancel closure, enabling active cancellation
- **Transport emits raw Data** — Transport handles framing (SSE line parsing, WS frame boundaries), Provider handles semantics

**Planned implementations:**
- `HTTPTransport` — URLSession-based SSE (universal)
- `WebSocketTransport` — for OpenAI Responses API
- `TransportChain` — ordered fallback list of transports
- `MockTransport` — testing with canned responses

### Provider

```swift
enum ContentBlock: Sendable {
    case text(String)
    case reasoning(String)
    // future: case toolUse(ToolCall)
}

enum StopReason: Sendable, Equatable {
    case stop
    case length
    case contentFilter
    // future: case toolUse
}

enum ProviderEvent: Sendable {
    case reasoningDelta(String)
    case textDelta(String)
    // future: case toolCall(ToolCall)
    case done(StopReason)
}

struct ResponseStream: Sendable {
    let events: AsyncThrowingStream<ProviderEvent, Error>
    let cancel: @Sendable () async -> Void
}

struct ProviderRequest: Sendable {
    var model: String
    var system: String?
    var messages: [Message]
    var maxTokens: Int
    var temperature: Double?
    // future: var tools: [ToolDefinition], var toolChoice: ToolChoice
}

protocol Provider: Sendable {
    func send(_ request: ProviderRequest) async throws -> ResponseStream
}
```

- **Provider owns the Transport** (composed at init, not a separate pluggable layer)
- **Provider buffers tool call deltas** — emits complete events (not implemented yet)
- **Text deltas stream individually** — useful for UI display
- **Provider decides statefulness** — e.g. OpenAI provider uses `previous_response_id` when the server supports it, regardless of transport

**Provider-specific configuration:**

Reasoning parameters and other provider-specific knobs are handled by the concrete provider, not the generic `ProviderRequest`. Configuration methods live on concrete providers:

```swift
final class OpenAIProvider: Provider {
    struct Configuration: Sendable {
        var reasoningEffort: ReasoningEffort?
    }
    enum ReasoningEffort: String, Sendable {
        case low, medium, high
    }
    func configure(_ settings: Configuration) async throws { ... }
    func send(_ request: ProviderRequest) async throws -> ResponseStream { ... }
}
```

The provider maintains an internal model registry with sensible defaults. Users only override when they want to change behavior.

**Content block mapping by provider:**

| Provider | Format | Mapping to `[ContentBlock]` |
|----------|--------|-----------------------------|
| Anthropic | `content: [{type: "thinking"}, {type: "text"}]` | Direct 1:1 — already content blocks |
| OpenAI Responses | `output: [{type: "reasoning"}, {type: "message"}, {type: "function_call"}]` | Direct 1:1 |
| OpenAI Chat Completions | `message: {content, reasoning_content, tool_calls}` | Provider assembles into blocks |
| Mistral | `message: {content, tool_calls}` | Provider assembles into blocks |
| DeepSeek | `message: {content, reasoning_content, tool_calls}` | Provider assembles into blocks |

### Messages

```swift
enum Message: Sendable {
    case user(String)
    case assistant(AssistantMessage)
    // future: case toolResult(ToolResultMessage)
}

struct AssistantMessage: Sendable {
    var content: [ContentBlock]
    var stopReason: StopReason
}
```

- **ContentBlock** maps naturally to how providers return data (Anthropic's `content[]` blocks, OpenAI's output items)
- **Preserves turn grouping** for history replay
- **Extends naturally** when adding tools (add `.toolUse` case)

### Session

```swift
protocol Session: Sendable {
    func messages() async -> [Message]
    func append(_ message: Message) async throws
}
```

- Two operations — read history, append to it
- Request construction is the caller's job — the session just provides message history
- Conforming types handle their own storage and concurrency model

**Planned implementations:**
- `InMemorySession` — actor, `[Message]` array
- `SQLiteSession` — persistent disk storage
- `FileSession` — JSONL append-only log

### Errors

```swift
enum JuliusError: Error, Sendable {
    case connectionFailed(String)
    case requestSerializationFailed(String)
    case responseParsingFailed(String)
    case transportDisconnected
}
```

## Testing Strategy

Each layer is independently testable via protocol-based mocking:

```swift
// Test provider serialization + parsing with mock transport
let transport = MockTransport(cannedResponse: ssePayloadFromFile)
let provider = OpenAIProvider(transport: transport, apiKey: "test")

// Test caller logic with mock provider
let provider = MockProvider(cannedEvents: [.textDelta("hello"), .done(.stop)])
```

## Decisions Log

| Decision | Rationale |
|----------|-----------|
| Single Transport protocol | HTTPTransport fakes persistence (connect/disconnect are no-ops). No capability queries needed. |
| Transport composed with Provider at init | Provider owns the transport as an implementation detail. Caller doesn't know about transport. |
| TransportChain for fallback | Ordered list of transports, tries each in sequence on connection failure. |
| Provider decides statefulness | OpenAI uses `previous_response_id` when available. Provider-level concern, not transport-level. |
| InFlight return type | `send()` returns both event stream and cancel closure, enabling active cancellation (e.g. OpenAI's `response.cancel` frame). |
| Tool arguments as raw String | Models don't always produce valid JSON; tool implementations handle parsing. (Not implemented yet.) |
| ContentBlock enum | Maps directly to how providers return data. Preserves turn grouping. Extends naturally for tools. |
| Provider-specific config on concrete types | Keeps Provider protocol clean. Provider maintains model registry with defaults. |
| Cancel everything + repair context | When user interrupts, all in-flight work is cancelled via Swift Task.cancel. Interrupted tool calls are patched with `<user_cancellation>` messages before next turn. (Not implemented yet.) |

## Not Yet Implemented

The following are designed but deferred to later iterations:

- **Tool system** — `ToolRegistry` protocol, `ToolDefinition`, `ToolCall`, `ToolResultMessage`, tool-related `ProviderEvent`
- **Agent loop** — ReAct pattern: reason, act, observe, repeat
- **WebSocket transport** — for OpenAI Responses API
- **TransportChain** — ordered fallback
- **Cancellation context repair** — patching interrupted tool calls with `<user_cancellation>` messages
- **Anthropic provider** — HTTP + SSE only
- **Additional session backends** — SQLite, filesystem
