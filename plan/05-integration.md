# 05 — Integration Test

## Status: not started

## Depends on
01, 02, 03, 04

## Scope
- End-to-end single-turn flow using real implementations (except Transport is mocked)
- Validates that all layers compose correctly

## Files
| File | Action |
|------|--------|
| `Tests/juliusTests/IntegrationTests.swift` | Create |

## Test flow
1. Create `InMemorySession`
2. Append a user message
3. Create `MockTransport` with canned OpenAI SSE response
4. Create `OpenAIProvider` with mock transport
5. Load history from session, build `ProviderRequest`
6. Call `provider.send(request)`
7. Consume `ResponseStream.events`, accumulate into `AssistantMessage`
8. Append `AssistantMessage` to session
9. Verify session contains both user and assistant messages
10. Verify `AssistantMessage.content` and `stopReason` match canned response

## Acceptance criteria
- [ ] `mise run build` passes
- [ ] Full turn cycle completes without error
- [ ] Session history is correct after turn
- [ ] Streaming deltas accumulate into final message correctly
