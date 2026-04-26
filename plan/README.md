# Implementation Plan

| # | Unit | Status | Depends on |
|---|------|--------|------------|
| 01 | Core Types + Package Setup | done | — |
| 02 | Transport Protocol + HTTPTransport | done | 01 |
| 03 | Session Protocol + InMemorySession | done | 01 |
| 04 | Provider Protocol + OpenAIProvider | done | 01, 02 |
| 05 | Integration Test | done | 01, 02, 03, 04 |
| 06 | Provider Endpoint Path | not started | 04 |
| 07 | Loop (ReAct Loop) | not started | 01, 02, 03, 04 |
| 08 | CLI Test Client | not started | 06, 07 |

Status: `not started` | `in progress` | `done`
