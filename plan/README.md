# Implementation Plan

| # | Unit | Status | Depends on |
|---|------|--------|------------|
| 01 | Core Types + Package Setup | done | — |
| 02 | Transport Protocol + HTTPTransport | done | 01 |
| 03 | Session Protocol + InMemorySession | done | 01 |
| 04 | Provider Protocol + OpenAIProvider | done | 01, 02 |
| 05 | Integration Test | not started | 01, 02, 03, 04 |

Status: `not started` | `in progress` | `done`
