# Implementation Plan

| # | Kind | Unit | Status | Depends on |
|---|------|------|--------|------------|
| 01 | feature | Core Types + Package Setup | done | — |
| 02 | feature | Transport Protocol + HTTPTransport | done | 01 |
| 03 | feature | Session Protocol + InMemorySession | done | 01 |
| 04 | feature | Provider Protocol + OpenAIProvider | done | 01, 02 |
| 05 | feature | Integration Test | done | 01, 02, 03, 04 |
| 06 | feature | Provider Endpoint Path | done | 04 |
| 07 | feature | Loop (ReAct Loop) | done | 01, 02, 03, 04 |
| 08 | feature | CLI Test Client | done | 06, 07 |
| 09 | feature | Streaming Display | done | 07 |
| 10 | feature | ArgumentParser Refactor | done | 08 |
| 11 | bug | Pass CLI args through `mise run dev` | done | — |
| 12 | feature | Tools Management | done | 07 |
| 13 | feature | Compaction | done | 07, 12 |
| 14 | feature | Initialize Zoomies (Agent) | not started | 12 |
| 15 | feature | Bash Tool + Tree-Sitter | not started | 14 |
| 16 | feature | Programmatic Tool Calling (Lua) | draft | 14, 15 |
| 17 | feature | Text Editor Tool | draft | 14 |

Status: `not started` | `draft` | `in progress` | `done`
