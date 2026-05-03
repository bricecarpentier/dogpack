# 18 — Agent Skills

## Status: not started

## Depends on
14 (Initialize Zoomies)

## Problem
Agents need to dynamically adapt their behavior based on the task at hand. Hardcoding all behavior into the agent runtime is inflexible — users should be able to add, remove, and compose skills without modifying agent code. There is an emerging standard format (agentskills.io) for skill definition that enables portability across agent implementations.

## Scope
Add skill support across three libraries following the Agent Skills specification. `tricks` is a new standalone library for skill types, parsing, and validation. `zoomies` handles agent integration (prompt composition, three-tier loading). `dogpack` owns the real world (filesystem, config, prediction, LLM resolver). Skills are activated at session level, not per-turn. A three-tier pre-loading system (very-high, high, low usage) determines how aggressively skills and resources are loaded, driven by cross-session usage history tracked at the CLI level.

## Files

### Tricks (skill library — standalone)
| File | Action |
|------|--------|
| `Package.swift` | Modify — add `tricks` library product and target |
| `Sources/tricks/SkillManifest.swift` | Create — skill data type |
| `Sources/tricks/FrontmatterParser.swift` | Create — YAML frontmatter parsing (Yams) |
| `Sources/tricks/SkillStore.swift` | Create — in-memory skill index |
| `Sources/tricks/SkillResolver.swift` | Create — resolver protocol + keyword matching |
| `Sources/tricks/SkillConfig.swift` | Create — resource loader closure + tier assignments |
| `Sources/tricks/SkillValidation.swift` | Create — name/description validation rules |
| `Tests/tricksTests/SkillManifestTests.swift` | Create — parsing and validation tests |
| `Tests/tricksTests/SkillStoreTests.swift` | Create — indexing and querying tests |
| `Tests/tricksTests/SkillResolverTests.swift` | Create — keyword matching tests |

### Zoomies (agent runtime)
| File | Action |
|------|--------|
| `Sources/zoomies/Skills/SkillComposer.swift` | Create — compose system prompt + context messages from skills |
| `Sources/zoomies/Agent.swift` | Modify — accept SkillConfig, integrate three-tier loading |
| `Tests/zoomiesTests/SkillComposerTests.swift` | Create — prompt composition tests |

### Dogpack (CLI)
| File | Action |
|------|--------|
| `Sources/dogpack/SkillScanner.swift` | Create — scan filesystem, build SkillManifest array |
| `Sources/dogpack/SkillPredictor.swift` | Create — cross-session usage tracking + prediction |
| `Sources/dogpack/LLMSkillResolver.swift` | Create — small-model router implementation of SkillResolver |
| `Sources/dogpack/SkillConfigBuilder.swift` | Create — wire up scanner, predictor, resolver into SkillConfig |

## Design

### Library dependency chain

```
dogpack ──→ zoomies ──→ julius
  │            │
  └──→ tricks ←┘
    │     │
    │     └──→ Yams (YAML frontmatter parsing)
    │
    └──→ TOMLKit (config file parsing)
```

- **tricks** — standalone. Depends only on Yams. No dependency on julius.
- **zoomies** — depends on julius + tricks. Owns agent integration, prompt composition.
- **dogpack** — depends on zoomies + tricks + TOMLKit. Owns filesystem, config, prediction.

### Separation of concerns

```
tricks (spec compliance)        zoomies (agent runtime)       dogpack (real world)
┌────────────────────┐         ┌────────────────────┐        ┌────────────────────┐
│ SkillManifest       │         │ SkillComposer       │        │ SkillScanner        │
│ FrontmatterParser   │         │ three-tier loading  │        │ (FileManager)       │
│ SkillStore          │         │ prompt composition  │        │ SkillPredictor      │
│ SkillResolver proto │         │ per-turn check      │        │ (usage history)     │
│ SkillValidation     │         │                    │        │ LLMSkillResolver    │
│ SkillConfig         │         │                    │        │ SkillConfigBuilder  │
│ KeywordSkillResolver│         │                    │        │                     │
└────────────────────┘         └────────────────────┘        └────────────────────┘
  Pure functions                  Conversation layer           Filesystem + config
  String → SkillManifest          Injects into prompts         Reads files from disk
  No filesystem                   No filesystem                Tracks usage across sessions
```

### Skill directory structure (from agentskills.io spec)

```
skill-name/
├── SKILL.md          # Required: YAML frontmatter + markdown instructions
├── scripts/          # Optional: executable code
├── references/       # Optional: additional documentation
├── assets/           # Optional: templates, resources
└── ...               # Any additional files
```

### SKILL.md format

```markdown
---
name: code-review
description: Review code for bugs, style issues, and security vulnerabilities. Use when the user asks to review a PR or code changes.
license: Apache-2.0
compatibility: Requires git
metadata:
  author: dogpack-team
  version: "1.0"
allowed-tools: text_editor bash
---

# Code Review Skill

## Instructions
1. Read the changed files
2. Check for common issues:
   ...
```

### Progressive disclosure

The spec defines three loading levels:

| Level | What's loaded | When | Approx. tokens |
|-------|--------------|------|----------------|
| 1. Metadata | `name` + `description` from frontmatter | Agent startup | ~100 |
| 2. Instructions | Full SKILL.md body | Session start (high-usage) or on demand (low-usage) | <5000 recommended |
| 3. Resources | Files in scripts/, references/, assets/ | Session start (very-high usage) or on demand | As needed |

### Cache-aware design

LLM APIs cache prompt prefixes. The system prompt must be composed once at session start and remain immutable for the entire session. Dynamic content goes in the message history, never in the system prompt.

```
System prompt (composed once at session start, immutable):
├── Base instructions
├── Very-high-usage skill instructions
├── High-usage skill instructions
└── [no low-usage skills, no resources]

Message history (grows each turn, prefix cached):
├── [background context: very-high skill resources]     ← turn 1, cached from turn 2
├── User msg 1
├── Assistant msg 1
├── [context: newly resolved skill instructions + resources]  ← injected when low-usage skill detected
├── User msg N
└── ...
```

The system prompt cache never breaks. The message prefix cache breaks once when a new skill is injected mid-session, then that injection becomes part of the cached prefix.

### Three-tier skill loading

Skills are classified into three tiers based on predicted usage from cross-session history:

| Tier | Instructions | Resources | Where | Cache cost |
|------|-------------|-----------|-------|------------|
| Very high | System prompt (turn 1) | Background context message (turn 1) | System prompt + first message | Cached from turn 1-2 |
| High | System prompt (turn 1) | On demand (when referenced) | System prompt + message history | Instructions cached, resources one miss |
| Low | On demand (when resolver detects need) | On demand (same time) | Message history only | One miss per new skill |

Tier assignments come from `SkillPredictor` (dogpack), which tracks cross-session usage.

### `allowed-tools` is informational

The `allowed-tools` field from SKILL.md frontmatter is **not enforced** by the runtime. It's included in the skill instructions injected into the prompt. The model reads it and self-constrains. This avoids hard-filtering edge cases and keeps the tool registry simple.

### SkillManifest — data type (tricks)

```swift
/// Parsed representation of a SKILL.md file.
public struct SkillManifest: Equatable, Sendable {
    public var name: String           // required, validated
    public var description: String    // required
    public var license: String?
    public var compatibility: String?
    public var metadata: [String: String]
    public var allowedTools: [String] // space-separated → [String]

    /// Raw markdown body after frontmatter.
    public var instructions: String
}
```

### SkillValidation — validation rules (tricks)

```swift
public enum SkillValidation {
    /// Validate a skill name. Returns nil if valid, error description if invalid.
    public static func validateName(_ name: String) -> String?

    /// Validate that a manifest's name matches its directory name.
    public static func validateDirectoryName(_ name: String, directory: String) -> String?

    /// Validate a description. Returns nil if valid, error description if invalid.
    public static func validateDescription(_ description: String) -> String?

    /// Validate a compatibility string. Returns nil if valid, error description if invalid.
    /// Nil input is valid (field is optional). Non-nil must be 1-500 chars.
    public static func validateCompatibility(_ compatibility: String?) -> String?
}
```

Rules (from [agentskills.io spec](https://agentskills.io/specification)):
- `name`: 1-64 chars, lowercase alphanumeric (`a-z`, `0-9`) and hyphens (`-`) only, no leading/trailing/consecutive hyphens
- `name` must match parent directory name
- `description`: 1-1024 chars, non-empty
- `compatibility`: optional, but if provided must be 1-500 chars

### FrontmatterParser — YAML parsing (tricks)

```swift
import Yams

/// Parses YAML frontmatter from a SKILL.md file content.
/// Format: ---\n<yaml>\n---\n<markdown body>
/// Pure function — takes a string, returns structured data. No filesystem.
public struct FrontmatterParser {
    public static func parse(_ content: String) throws -> SkillManifest
}
```

Uses [Yams](https://github.com/jpsim/Yams) (built on libyaml, supports Codable, actively maintained). Handles all YAML edge cases (multiline strings, type coercion, quoting) that a hand-rolled parser would miss — particularly important for the arbitrary `metadata` field.

### SkillStore — in-memory index (tricks)

```swift
/// In-memory index of skill manifests. No filesystem access.
public final class SkillStore: Sendable {
    private var manifests: [String: SkillManifest]  // name → manifest

    /// Build from an array of pre-parsed manifests.
    public init(manifests: [SkillManifest])

    /// All indexed skill names + descriptions (level 1 metadata).
    public var availableSkills: [(name: String, description: String)]

    /// Look up a full manifest by name.
    public func manifest(for name: String) -> SkillManifest?
}
```

Dogpack creates manifests from files and passes them to `init(manifests:)`. Tricks never touches the filesystem.

### ResourceRequest — typed resource access (tricks)

```swift
/// Identifies a resource file within a skill directory.
public struct ResourceRequest: Equatable, Sendable {
    public var skillName: String
    public var relativePath: String   // e.g. "references/STYLE_GUIDE.md"
}
```

### SkillConfig — configuration container (tricks)

```swift
/// Configuration for how the agent should handle skills.
/// Built by dogpack, injected into zoomies.
public struct SkillConfig: Sendable {
    /// The skill store (in-memory index).
    public var store: SkillStore

    /// The resolver for detecting low-usage skills per-turn.
    public var resolver: SkillResolver

    /// Tier assignments from the predictor.
    public var tiers: SkillTiers
}

/// Skill tier assignments from cross-session prediction.
public struct SkillTiers: Equatable, Sendable {
    public var veryHigh: Set<String>
    public var high: Set<String>
    public var low: Set<String>  // everything not in veryHigh or high
}
```

Note: the resource loader is not in `SkillConfig`. It is owned by `SkillComposer` (see below), which receives it at init time from the Agent. Dogpack creates the closure (wrapping `FileManager`), the Agent passes it through to `SkillComposer`.

### SkillResolver — protocol (tricks)

```swift
/// Determines which skills are relevant for a given message.
/// Concrete implementations are provided by the CLI layer.
public protocol SkillResolver: Sendable {
    func resolve(
        userMessage: String,
        availableSkills: [(name: String, description: String)]
    ) async -> [String]
}
```

**KeywordSkillResolver (tricks)** — built-in keyword matching:

```swift
public struct KeywordSkillResolver: SkillResolver {
    public func resolve(
        userMessage: String,
        availableSkills: [(name: String, description: String)]
    ) async -> [String]
}
```

**LLMSkillResolver (dogpack)** — small, cheap model as classifier:

```swift
// In dogpack, not tricks
struct LLMSkillResolver: SkillResolver {
    let provider: Provider  // pointed at cheap model
    let model: String

    func resolve(...) async -> [String]
}
```

**Hybrid (dogpack)** — keyword first, LLM fallback on low confidence.

The resolver is created by dogpack and injected via `SkillConfig`. Zoomies has no knowledge of which strategy is in use.

### SkillComposer — prompt composition (zoomies)

```swift
/// Composes system prompt and context messages from active skills.
/// Owns the resource loader — receives it at init time from the Agent.
public struct SkillComposer: Sendable {
    private let resourceLoader: @Sendable (ResourceRequest) throws -> String

    public init(resourceLoader: @escaping @Sendable (ResourceRequest) throws -> String)

    /// Build the immutable system prompt from base instructions + high-usage skill instructions.
    public func composeSystemPrompt(
        baseInstructions: String,
        skills: [SkillManifest]
    ) -> String

    /// Build background context message for very-high skill resources.
    public func composeBackgroundContext(
        skills: [SkillManifest]
    ) throws -> String

    /// Build a context message for a newly activated low-usage skill.
    public func composeActivationContext(
        skill: SkillManifest,
        resources: [String]?
    ) throws -> String
}
```

System prompt composition (alphabetical order for cache stability):

```
[base instructions]

[Skill: code-review]
{SKILL.md body content}
[End skill: code-review]

[Skill: git-commit]
{SKILL.md body content}
[End skill: git-commit]
```

### Dogpack components

**SkillScanner** — reads skill directories from filesystem, parses SKILL.md files using `FrontmatterParser`, validates, returns `[SkillManifest]`. Invalid skills are skipped with a logged warning.

**SkillPredictor** — tracks skill usage across sessions in a local file (`~/.config/dogpack/skill-usage.json`). Uses frequency with recency weighting (exponential decay) to predict tier assignments for the next session. Records: `{ timestamp, session_id, skills: [...], resource_loads: [...] }`.

**Always-load config** — the user config (`~/.config/dogpack/config.toml`) specifies skills that should always be loaded at very-high tier, regardless of usage history. This solves the cold-start problem (fresh install, no history) and lets users pin essential skills. Parsed using [TOMLKit](https://github.com/LebJe/TOMLKit) (Codable-based TOML decoder).

```toml
# ~/.config/dogpack/config.toml
[skills]
directories = ["~/.dogpack/skills"]
always-load = ["text-editor", "bash"]
```

The `SkillPredictor` treats `always-load` entries as very-high tier. Usage history fills in the rest.

**LLMSkillResolver** — sends user message + skill metadata to a cheap model (e.g., Haiku, GPT-4o-mini) for classification. ~0.1% of main model cost per call.

**SkillConfigBuilder** — wires scanner, predictor, and resolver together into a `SkillConfig` ready to inject into the agent.

### Agent integration

**At session start (one-time setup):**
1. Dogpack scans directories → `[SkillManifest]` → `SkillStore`
2. Dogpack reads config → `always-load` list
3. Dogpack predicts tiers → `SkillTiers`
4. Dogpack builds `SkillConfig` (store + resolver + tiers)
5. Dogpack creates resource loader closure (wraps FileManager)
6. Dogpack passes `SkillConfig` + resource loader to `Agent.init`
7. Agent creates `SkillComposer(resourceLoader:)` from the passed closure
8. Agent calls `skillComposer.composeSystemPrompt(...)` from very-high + high skill instructions
9. Agent calls `skillComposer.composeBackgroundContext(...)` from very-high resources
10. System prompt is composed and frozen — never changes again

**Per turn (lightweight check):**

```
Agent loop (each turn):
    1. Receive user message
    2. Call resolver.resolve(userMessage:, availableSkills:)
       → returns list of skill names relevant to this message
    3. Filter: keep only skills not yet active this session
    4. For each newly resolved skill (typically 0-1):
       a. Look up manifest from store
       b. Call skillComposer.composeActivationContext(skill:, resources:)
       c. Inject the context message into conversation history
          BEFORE the current user message
    5. Send full conversation (system prompt + history + context + user msg)
       to the LLM
    6. Process LLM response (tool calls, text, etc.)
```

If the resolver returns multiple skills, all are activated and injected as separate context messages in alphabetical order (for determinism). Already-active skills are tracked in a `Set<String>` on the Agent and skipped on subsequent turns.

### Package.swift changes

```swift
products: [
    .library(name: "julius", targets: ["julius"]),
    .library(name: "tricks", targets: ["tricks"]),      // NEW
    .library(name: "zoomies", targets: ["zoomies"]),
],
dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.1"),
    .package(url: "https://github.com/jpsim/Yams", from: "5.2.0"),
    .package(url: "https://github.com/LebJe/TOMLKit", from: "0.6.0"),
],
targets: [
    // Existing targets...
    .target(name: "tricks", dependencies: [
        .product(name: "Yams", package: "Yams"),
    ]),
    .target(name: "zoomies", dependencies: ["julius", "tricks"]),
    .target(name: "dogpack", dependencies: [
        "zoomies",
        "tricks",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "TOMLKit", package: "TOMLKit"),
    ]),
    .testTarget(name: "tricksTests", dependencies: ["tricks"]),
    .testTarget(name: "zoomiesTests", dependencies: ["zoomies"]),
]
```

## Acceptance criteria
- [ ] `tricks` target compiles as a standalone library depending only on Yams
- [ ] `tricksTests` target compiles and runs
- [ ] TOMLKit added as SPM dependency, dogpack target links it
- [ ] `FrontmatterParser` extracts YAML frontmatter and markdown body from SKILL.md content strings
- [ ] `SkillManifest` data type with all spec fields
- [ ] `SkillValidation` enforces spec rules: name (lowercase alphanumeric + hyphens, 1-64 chars), description (1-1024 chars), directory name match, compatibility (1-500 chars if provided)
- [ ] `SkillStore` indexes manifests in-memory, queries by name
- [ ] `SkillResolver` protocol with `KeywordSkillResolver` default implementation
- [ ] `ResourceRequest` struct with `skillName` + `relativePath` labels
- [ ] `SkillConfig` holds store, resolver, and tiers (no resource loader)
- [ ] `SkillTiers` data type for very-high/high/low assignments
- [ ] `SkillComposer` owns resource loader via init, uses `ResourceRequest` for file access
- [ ] `SkillComposer` builds system prompt from skill instructions (alphabetical order)
- [ ] `SkillComposer` builds background context message for very-high resources
- [ ] `SkillComposer` builds activation context for low-usage skills
- [ ] Agent composes system prompt once at session start, never mutates it
- [ ] Per-turn resolver check detects low-usage skills, filters already-active, injects as context messages before user message
- [ ] Multiple resolved skills injected in alphabetical order
- [ ] Agent tracks active skills in `Set<String>` across turns
- [ ] `allowed-tools` included in instructions but not runtime-enforced
- [ ] Dogpack provides `SkillScanner`, `SkillPredictor`, `LLMSkillResolver`, `SkillConfigBuilder`
- [ ] Dogpack config parsed from TOML via TOMLKit (always-load, directories)
- [ ] No filesystem access in tricks or zoomies
- [ ] All existing tests pass unchanged
