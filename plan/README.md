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
| 09 | feature | Streaming Display | not started | 07 |
| 10 | feature | ArgumentParser Refactor | not started | 08 |
| 11 | bug | Pass CLI args through `mise run dev` | done | — |

Status: `not started` | `in progress` | `done`
