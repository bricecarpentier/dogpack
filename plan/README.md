# Implementation Plan

| # | Unit | Status | Depends on |
|---|------|--------|------------|
| 01 | Core Types + Package Setup | done | — |
| 02 | Transport Protocol + HTTPTransport | done | 01 |
| 03 | Session Protocol + InMemorySession | done | 01 |
| 04 | Provider Protocol + OpenAIProvider | done | 01, 02 |
| 05 | Integration Test | done | 01, 02, 03, 04 |
| 06 | Provider Endpoint Path | done | 04 |
| 07 | Loop (ReAct Loop) | done | 01, 02, 03, 04 |
| 08 | CLI Test Client | done | 06, 07 |
| 09 | Streaming Display | not started | 07 |
| 10 | ArgumentParser Refactor | not started | 08 |

Status: `not started` | `in progress` | `done`
