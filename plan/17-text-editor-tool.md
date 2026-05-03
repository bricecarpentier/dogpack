# 17 — Text Editor Tool

## Status: draft

## Depends on
14 (Initialize Zoomies)

## Problem
The LLM needs to view, create, and modify files. Without a dedicated file editing tool, the only option is the bash tool (plan 15), which is error-prone for file operations — shell quoting issues, no structured output, ambiguous intent, and no safety constraints.

## Scope
Add a text editor tool in zoomies that provides four structured file operations: view, create, str_replace, and insert. Modeled after Anthropic's `str_replace_based_edit_tool`. The tool conforms to the `Tool` protocol from plan 14 and replaces the need for separate `read_file`/`write_file` tools.

## Files
| File | Action |
|------|--------|
| `Sources/zoomies/Tools/TextEditorTool.swift` | Create — text editor tool conforming to `Tool`, all four commands |
| `Sources/zoomies/Tools/TextEditorTypes.swift` | Create — command enum, validation types, result types |
| `Tests/zoomiesTests/TextEditorToolTests.swift` | Create — tests for all four commands + error cases |

## Design

### Why a dedicated tool instead of bash

| Concern | Bash tool | Text editor tool |
|---------|-----------|-----------------|
| Safety | Can `rm -rf` | Read/create/edit only |
| Output | stdout/stderr mixed | Structured: content, line numbers, truncation flag |
| Quoting | Shell escaping for file content | No shell involved |
| Intent | `bash("cat foo")` — ambiguous | `view(path="foo")` — explicit |
| Edits | `sed` — error-prone | `str_replace` — exact match, unique enforcement |

### Tool definition (presented to the LLM)

```json
{
  "name": "text_editor",
  "description": "View, create, and edit text files. Supports viewing files or directories, creating new files, targeted string replacement, and line insertion.",
  "input_schema": {
    "type": "object",
    "properties": {
      "command": {
        "type": "string",
        "enum": ["view", "create", "str_replace", "insert"],
        "description": "The operation to perform"
      },
      "path": {
        "type": "string",
        "description": "Absolute path to the file or directory"
      },
      "file_text": {
        "type": "string",
        "description": "Content for the 'create' command"
      },
      "old_str": {
        "type": "string",
        "description": "Text to find for 'str_replace'. Must match exactly once."
      },
      "new_str": {
        "type": "string",
        "description": "Replacement text for 'str_replace'"
      },
      "insert_line": {
        "type": "integer",
        "description": "Line number after which to insert (0 for beginning)"
      },
      "insert_text": {
        "type": "string",
        "description": "Text to insert for the 'insert' command"
      },
      "view_range": {
        "type": "array",
        "items": { "type": "integer" },
        "description": "[start, end] line range for 'view'. 1-indexed, -1 for end of file."
      }
    },
    "required": ["command", "path"]
  }
}
```

### Commands

#### view
- On a file: returns contents with line numbers prepended, respecting `view_range`
- On a directory: returns listing of entry names only, non-recursive (matching Anthropic's behavior)
- Truncation at configurable `maxCharacters` (set at tool init time)

#### create
- Creates a new file at `path` with `file_text` content
- Fails if the file already exists (prevents accidental overwrites)

#### str_replace
- Finds `old_str` in the file, replaces with `new_str`
- **Must match exactly once** — fails on zero matches (typo) or multiple matches (ambiguous)
- Exact matching includes whitespace and indentation
- Returns confirmation of the replacement

#### insert
- Inserts `insert_text` after `insert_line` (0 = beginning of file)
- Returns confirmation with context
- Kept alongside `str_replace` for convenience when adding new code blocks (matching Anthropic's tool design)

### TextEditorTool (conforms to Tool)

```swift
import julius

public struct TextEditorTool: Tool, Sendable {
    public let definition: ToolDefinition
    private let maxCharacters: Int
    private let allowedPaths: Set<String>?  // optional path restriction

    public init(
        maxCharacters: Int = 50_000,
        allowedPaths: Set<String>? = nil
    )

    public func execute(_ call: ToolCall) async throws -> ToolResult
}
```

### Internal command dispatch

```swift
private enum Command: String {
    case view
    case create
    case strReplace = "str_replace"
    case insert
}

private func executeView(path: String, viewRange: [Int]?) throws -> String
private func executeCreate(path: String, fileText: String) throws -> String
private func executeStrReplace(path: String, oldStr: String, newStr: String) throws -> String
private func executeInsert(path: String, insertLine: Int, insertText: String) throws -> String
```

### View output format

File contents returned with line numbers:
```
     1  import Foundation
     2  
     3  public struct Foo {
     4      public var bar: String
     5  }
```

Truncation indicator appended if content exceeds `maxCharacters`:
```
[File truncated at 50000 characters. Use view_range to read specific sections.]
```

### Error handling

All errors returned as ToolResult (not thrown), so the model gets actionable feedback:

| Error | When |
|-------|------|
| File not found | `view`/`str_replace`/`insert` on non-existent path |
| File already exists | `create` on existing path |
| No match found | `str_replace` where `old_str` doesn't match |
| Multiple matches | `str_replace` where `old_str` matches more than once |
| Invalid view_range | Range out of bounds or malformed |
| Path not allowed | Path outside `allowedPaths` |
| Encoding error | File is not valid UTF-8 (binary or unsupported encoding) |

### Safety

- Path validation: reject `..` traversal, enforce `allowedPaths` if set
- Read-only by default for `view` — no filesystem mutation
- `create` fails on existing files — no silent overwrites
- `str_replace` unique-match enforcement — no accidental multi-edits; this also acts as an **implicit optimistic lock** — if the file changes between `view` and `str_replace`, the `old_str` will likely no longer match, causing a clean failure rather than a silent corrupt edit
- All file I/O assumes UTF-8 encoding; non-UTF-8 files return an encoding error
- No shell invocation — no injection surface

## Acceptance criteria
- [ ] `TextEditorTool` conforms to `Tool` protocol from plan 14
- [ ] `view` on file returns line-numbered content with truncation
- [ ] `view` on directory returns listing of entry names only, non-recursive
- [ ] `view` respects `view_range` for partial reads
- [ ] `create` creates new file, fails if file exists
- [ ] `str_replace` replaces exact unique match, fails on zero or multiple matches (acts as optimistic lock)
- [ ] Non-UTF-8 files return encoding error for all commands
- [ ] `insert` inserts text at specified line number
- [ ] Path validation prevents directory traversal
- [ ] `maxCharacters` truncation on view
- [ ] Optional `allowedPaths` restriction
- [ ] All errors returned as ToolResult with actionable messages
- [ ] Tests for all commands and error cases
- [ ] All existing tests pass unchanged
