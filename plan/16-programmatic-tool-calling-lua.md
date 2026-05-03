# 16 — Programmatic Tool Calling via Embedded Lua

## Status: draft

## Depends on
14 (Initialize Zoomies), 15 (Bash Tool + Tree-Sitter)

## Problem
Traditional tool calling requires a round-trip through the model for every single tool invocation. For workflows that call the same tool many times (e.g., querying 50 endpoints, processing files in a loop), this means N model round-trips, massive token consumption, and high latency. The model cannot loop, filter, or conditionally chain tool calls on its own.

## Scope
Implement programmatic tool calling using an embedded Lua interpreter in zoomies. The LLM generates Lua code that calls tools as native Lua functions. The code runs locally in a sandboxed Lua VM (via direct C library integration), with tree-sitter-lua validation of the generated code before execution. This eliminates round-trips for multi-step tool workflows: the model writes one Lua script, the script calls tools programmatically, and only the final result returns to the model's context.

## Files
| File | Action |
|------|--------|
| `Sources/zoomies/Lua/LuaBridge.swift` | Create — Swift-Lua C interop layer |
| `Sources/zoomies/Lua/LuaEngine.swift` | Create — embedded Lua VM, sandbox, execution |
| `Sources/zoomies/Lua/LuaToolRegistry.swift` | Create — expose registered tools as Lua functions |
| `Sources/zoomies/Lua/LuaValidator.swift` | Create — tree-sitter-lua parse and validate |
| `Sources/zoomies/Tools/LuaTool.swift` | Create — `execute_lua` tool conforming to `Tool`, orchestration |
| `Package.swift` | Modify — add Lua C library and tree-sitter-lua as SPM dependencies |
| `Tests/zoomiesTests/LuaEngineTests.swift` | Create — Lua execution, sandbox, tool bridge tests |

## Design

### Why Lua

- **Small footprint:** The Lua C library is ~200KB, compiles cleanly with Swift via SPM's C target support
- **Sandboxable:** Lua is designed for embedding — the standard library can be selectively exposed, `os.execute` and `io` can be removed
- **Fast:** No JIT needed for short scripts; the interpreter is fast enough for tool orchestration
- **Direct C integration:** No intermediate FFI framework needed — wrap `lua_*` calls directly in Swift

### Why not Anthropic-managed code execution

Anthropic's programmatic tool calling runs Python in their managed containers. For zoomies (a local agent), we want:
- Zero network round-trips for tool execution
- Full control over the sandbox
- No container management or expiration
- The model writes Lua, not Python — keeps the LLM in a constrained scripting environment

### Architecture

```
LLM generates Lua script
         │
         ▼
LuaValidator.validate(script)
         │
    ┌────┴────┐
    │  Valid? │
    └────┬────┘
     Yes │      │ No
         ▼      ▼
    LuaEngine   Return parse errors
    .execute()  to model
         │
         ▼
    Script calls tool functions
    (registered as Lua closures)
         │
         ▼
    LuaToolRegistry routes
    calls to real tool implementations
         │
         ▼
    Script returns final result
    (only this goes back to LLM context)
```

### Lua C library integration via SPM

Add Lua as a C library target in Package.swift. The Lua source can be vendored or pulled from a mirror:

```swift
// Package.swift
targets: [
    // Existing targets...
    .systemLibrary(name: "CLua"),  // or .target(name: "Lua", ...) with vendored source
]
```

The Lua C API (`lua.h`, `lauxlib.h`, `lualib.h`) is accessed directly from Swift via the generated module. No Swift wrapper framework needed — `LuaBridge.swift` provides the idiomatic Swift layer.

### LuaBridge — Swift <-> Lua interop

```swift
/// Low-level Swift wrapper around the Lua C API.
/// Provides type-safe push/get operations, call mechanism, and error handling.
final class LuaBridge {
    private(set) var state: OpaquePointer  // lua_State*

    init()                    // luaL_newstate
    deinit                    // lua_close

    func openLibs()           // luaL_openlibs (or selective subset)
    func sandbox()            // Remove os.execute, io, etc.

    func push(_ value: String)
    func push(_ value: Int)
    func push(_ value: Double)
    func push(_ value: Bool)
    func pushNil()

    func toString(at index: Int) -> String?
    func toNumber(at index: Int) -> Double?
    func toBool(at index: Int) -> Bool

    func getGlobal(_ name: String)
    func setGlobal(_ name: String)

    func call(nArgs: Int, nResults: Int) throws
    func pCall(nArgs: Int, nResults: Int) -> LuaStatus

    func pop(_ n: Int = 1)
    func getTop() -> Int
}
```

### LuaEngine — execution sandbox

```swift
public struct LuaEngine: Sendable {
    private let validator: LuaValidator

    /// Execute a Lua script with tool functions available.
    /// Returns the script's stdout output and any return value.
    public func execute(
        script: String,
        tools: [String: (String) async throws -> String]
    ) async throws -> LuaExecutionResult
}

public struct LuaExecutionResult: Equatable, Sendable {
    public var output: String          // captured stdout/print output
    public var returnValue: String?    // top-of-stack return value, serialized
    public var errors: [String]        // any runtime errors
    public var toolCalls: [ToolCallLog] // log of all tool invocations made
}

public struct ToolCallLog: Equatable, Sendable {
    public var toolName: String
    public var arguments: String
    public var result: String
}
```

The engine:
1. Creates a fresh Lua state per execution (no state leaks between runs)
2. Applies sandbox restrictions (no `os.execute`, no `io`, no `require` for arbitrary modules)
3. Registers tool functions as Lua globals via `lua_pushcfunction`
4. Captures `print()` output by overriding the `print` function
5. Runs the script with `lua_pcall` for safe error handling
6. Returns structured result

### LuaToolRegistry — tools as Lua functions

```swift
public final class LuaToolRegistry: Sendable {
    /// Register a tool implementation that the Lua script can call.
    public func register(
        name: String,
        schema: ToolDefinition,
        handler: @escaping (String) async throws -> String
    )

    /// Install all registered tools as Lua global functions.
    func install(into bridge: LuaBridge) throws
}
```

Each registered tool becomes a Lua function. When the Lua script calls it:

```lua
-- Model-generated Lua script
local result = query_database('SELECT * FROM users WHERE active = true')
local filtered = {}
for _, row in ipairs(result) do
    if row.revenue > 10000 then
        table.insert(filtered, row)
    end
end
print("High-value users: " .. #filtered)
```

The C callback (`lua_CFunction`) registered for `query_database`:
1. Extracts the string argument from the Lua stack
2. Calls the async handler (bridged to Swift's async/await)
3. Pushes the result string back onto the Lua stack
4. Returns 1 (one return value)

### LuaValidator — tree-sitter-lua validation

```swift
public struct LuaValidator: Sendable {
    /// Parse and validate Lua code using tree-sitter-lua.
    public func validate(_ code: String) -> LuaValidationResult
}

public enum LuaValidationResult: Equatable, Sendable {
    case valid
    case invalid(errors: [ParseError])
}
```

Same pattern as `BashValidator` (plan 15) but using the tree-sitter-lua grammar. Reuses `TreeSitterBridge` from plan 15. Validates that the model-generated Lua code is syntactically correct before executing it in the VM.

### LuaTool (conforms to Tool)

```swift
import julius

public struct LuaTool: Tool, Sendable {
    public let definition: ToolDefinition
    private let validator: LuaValidator
    private let engine: LuaEngine

    public init(registry: ToolRegistry)

    public func execute(_ call: ToolCall) async throws -> ToolResult
}
```

`LuaTool` receives the same `ToolRegistry` instance the Agent uses. This ensures the Lua VM has access to exactly the same tools the model sees — no separate tool list to keep in sync. The Lua engine extracts tool definitions from the registry to register as Lua functions.

The tool definition presented to the LLM:
```json
{
  "name": "execute_lua",
  "description": "Execute a Lua script that can call tools programmatically. All registered tools are available as Lua functions. Use this for multi-step workflows to avoid multiple round-trips.",
  "input_schema": {
    "type": "object",
    "properties": {
      "code": { "type": "string", "description": "Lua code to execute" }
    },
    "required": ["code"]
  }
}
```

### Cache-aware tool definition

The tool definition must be **stable across sessions**. It describes tools generically ("all registered tools are available") rather than enumerating specific tools. If the definition changed based on which tools are registered, the `tools` block in every request would differ between sessions, breaking the prompt cache. The actual list of available Lua-callable tools is conveyed to the model at runtime via tool results or system prompt, not baked into the `execute_lua` definition itself.

### Agent integration

The `Agent` from plan 14 treats `execute_lua` like any other tool. The key difference is that a single `execute_lua` call can internally invoke many tools. The `LuaExecutionResult.toolCalls` log is included in the `ToolResult` output so the model and caller can see what happened.

### Async bridging challenge

Lua is synchronous; tool handlers are async. The bridge uses a continuation-based approach:
1. Lua calls the tool C function
2. The C function stores a continuation and yields the Lua thread (`lua_yield`)
3. The Swift-side executor resumes the coroutine after the async tool completes
4. The result is pushed and Lua continues

This requires using Lua coroutines (`lua_newthread` + `lua_resume`) rather than plain `lua_pcall` for scripts that call tools.

## Acceptance criteria
- [ ] Lua C library compiles as SPM target and links successfully
- [ ] `LuaBridge` wraps core Lua C API with type-safe Swift interface
- [ ] `LuaEngine` creates sandboxed Lua state per execution (no `os.execute`, `io`, arbitrary `require`)
- [ ] `LuaValidator` validates Lua code via tree-sitter-lua before execution
- [ ] `LuaToolRegistry` registers tool handlers and exposes them as Lua global functions
- [ ] Tool calls from Lua are bridged to Swift async handlers via coroutine yield/resume
- [ ] `LuaTool` conforms to `Tool` protocol from plan 14
- [ ] `LuaExecutionResult` captures stdout, return value, errors, and tool call log
- [ ] Integration test: Lua script calls multiple tools, returns aggregated result
- [ ] Integration test: invalid Lua code returns parse errors without execution
- [ ] All existing tests pass unchanged
