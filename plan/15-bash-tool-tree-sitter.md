# 15 — Bash Tool + Tree-Sitter

## Status: not started

## Depends on
14 (Initialize Zoomies)

## Problem
The LLM generates shell commands that may contain syntax errors, leading to failed executions and wasted turns. There is no pre-execution validation layer to catch malformed commands before they reach the shell.

## Scope
Add a bash tool implementation in zoomies that validates generated shell commands using tree-sitter-bash before execution. The tool conforms to the `Tool` protocol from plan 14. Tree-sitter core and bash grammar C sources are vendored as local SPM targets, providing parse-time syntax checking that rejects invalid commands and reports parse errors back to the model.

## Files
| File | Action |
|------|--------|
| `Vendor/CTreeSitter/` | Create — vendored tree-sitter core C library (`src/*.c`, `include/tree_sitter/api.h`, `module.modulemap`) |
| `Vendor/CTreeSitterBash/` | Create — vendored bash grammar C sources (`src/parser.c`, `src/scanner.c`, `include/tree_sitter_bash.h`, `module.modulemap`) |
| `Sources/zoomies/TreeSitter/TreeSitterBridge.swift` | Create — shared tree-sitter C API wrapper for use by all validators |
| `Sources/zoomies/Tools/BashValidator.swift` | Create — tree-sitter-bash parse and validate, holds parser as state |
| `Sources/zoomies/Tools/BashTool.swift` | Create — bash tool conforming to `Tool`, execution, result handling |
| `Package.swift` | Modify — add `CTreeSitter` and `CTreeSitterBash` local targets, link to zoomies |
| `Tests/zoomiesTests/BashToolTests.swift` | Create — validation + execution tests |

### Vendored source versions
- tree-sitter core: v0.26.8 (from <https://github.com/tree-sitter/tree-sitter>)
- tree-sitter-bash: v0.25.1 (from <https://github.com/tree-sitter/tree-sitter-bash>)

## Design

### Tree-sitter integration — vendored C sources

tree-sitter grammars are C libraries with no SPM support (no `Package.swift`). We vendor the core library and bash grammar as local SPM targets with `module.modulemap` files. This is the standard pattern for integrating C libraries into Swift packages (used by Nova editor and others).

Directory structure:

```
Vendor/
├── CTreeSitter/              ← vendored tree-sitter core (from tree-sitter/lib/)
│   ├── include/
│   │   └── tree_sitter/
│   │       └── api.h
│   ├── src/
│   │   ├── parser.c
│   │   ├── lexer.c
│   │   ├── node.c
│   │   ├── tree.c
│   │   ├── language.c
│   │   └── ... (remaining core files)
│   └── module.modulemap
└── CTreeSitterBash/          ← vendored bash grammar (from tree-sitter-bash/src/)
    ├── include/
    │   └── tree_sitter_bash.h
    ├── src/
    │   ├── parser.c
    │   └── scanner.c
    └── module.modulemap
```
=======

`module.modulemap` for CTreeSitter:
```
module CTreeSitter {
    header "include/tree_sitter/api.h"
    link "c"
    export *
}
```

`module.modulemap` for CTreeSitterBash:
```
module CTreeSitterBash {
    header "include/tree_sitter_bash.h"
    link "c"
    export *
}
```

Package.swift targets:

```swift
targets: [
    // Existing targets...
    .target(name: "CTreeSitter", path: "Vendor/CTreeSitter"),           // vendored core
    .target(name: "CTreeSitterBash", path: "Vendor/CTreeSitterBash"),   // vendored bash grammar
    .target(
        name: "zoomies",
        dependencies: ["julius", "CTreeSitter", "CTreeSitterBash"]
    ),
]
```

The bash grammar exposes `tree_sitter_bash()` which returns a `TSLanguage *` for creating parsers.

### Validation flow

```
LLM generates bash command
        │
        ▼
BashValidator.parse(command)
        │
   ┌────┴────┐
   │  Valid? │
   └────┬────┘
    Yes │     │ No
        ▼     ▼
   Execute   Return ToolResult
   command   with parse error
        │     (no execution)
        ▼
   Return ToolResult
   with stdout/stderr/exitCode
```

### BashValidator

`BashValidator` holds a tree-sitter parser as stored state. Since it wraps a `ts_parser*` (a C pointer), it is implemented as a `final class` with `deinit` to free the parser. It conforms to `Sendable` via `@unchecked Sendable` since the underlying C pointer is not thread-safe but will be used from a single concurrency domain.

```swift
import CTreeSitter
import CTreeSitterBash

public final class BashValidator: @unchecked Sendable {
    private var parser: OpaquePointer  // TSParser*

    public init() {
        parser = ts_parser_new()
        ts_parser_set_language(parser, tree_sitter_bash())
    }

    deinit {
        ts_parser_delete(parser)
    }

    /// Parse a bash command string and return validation result.
    public func validate(_ command: String) -> BashValidationResult
}

public enum BashValidationResult: Equatable, Sendable {
    case valid
    case invalid(errors: [ParseError])
}

public struct ParseError: Equatable, Sendable {
    public var message: String
    public var line: Int
    public var column: Int
}
```

Uses tree-sitter's `ts_parser_parse_string` to parse the command. Traverses the resulting tree checking for error nodes (`ts_node_is_error`, `ts_node_has_error`) to detect syntax problems. Extracts line/column from error node start position via `ts_node_start_point`.

### BashTool (conforms to Tool)

```swift
import zoomies

public struct BashTool: Tool, Sendable {
    public let definition: ToolDefinition
    private let validator: BashValidator
    private let workingDirectory: String?
    private let timeout: TimeInterval

    public init(
        workingDirectory: String? = nil,
        timeout: TimeInterval = 30,
        allowedCommands: Set<String>? = nil
    )

    public func execute(_ call: ToolCall) async throws -> ToolResult
}
```

The tool definition describes the expected JSON schema:
```json
{
  "name": "bash",
  "description": "Execute a bash command. Commands are validated for syntax before execution.",
  "input_schema": {
    "type": "object",
    "properties": {
      "command": { "type": "string", "description": "The bash command to execute" }
    },
    "required": ["command"]
  }
}
```

### Execution

On valid parse, runs the command via `Process` (Foundation):
- Captures stdout and stderr
- Enforces timeout
- Returns exit code, stdout, stderr in the ToolResult output

On invalid parse, returns a ToolResult with the parse errors formatted as text, without executing anything. This gives the model actionable feedback to fix the command.

### Safety considerations

- Optional command allowlist (`allowedCommands`) to restrict which commands can run
- Timeout enforcement to prevent hanging processes
- Working directory scoping

### Shared TreeSitterBridge

The tree-sitter C API wrapper (`TreeSitterBridge.swift`) lives in zoomies and is shared by all tree-sitter validators (bash now, Lua in plan 16). It wraps `ts_parser_new`, `ts_parser_set_language`, `ts_parser_parse_string`, and error node traversal into a Swift-friendly interface.

## Acceptance criteria
- [ ] `CTreeSitter` target builds with vendored tree-sitter core C sources and modulemap
- [ ] `CTreeSitterBash` target builds with vendored bash grammar C sources and modulemap
- [ ] `TreeSitterBridge` provides reusable Swift wrapper for tree-sitter C API
- [ ] `BashValidator` holds parser as state (`final class`), parses commands and detects syntax errors
- [ ] `BashValidationResult` distinguishes valid from invalid with error details
- [ ] `BashTool` conforms to `Tool` protocol from plan 14, imports `zoomies` only
- [ ] `BashTool` validates before execution, rejects invalid commands with parse errors
- [ ] `BashTool` executes valid commands via `Process`, returns stdout/stderr/exitCode
- [ ] Timeout enforcement on command execution
- [ ] Tests: valid commands pass, invalid commands rejected, execution produces results
- [ ] All existing tests pass unchanged
