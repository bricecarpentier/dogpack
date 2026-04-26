# 06 — Provider Endpoint Path

## Status: done

## Depends on
04 (OpenAIProvider)

## Scope
- Move endpoint path (`/chat/completions`) into `OpenAIProvider`
- `OpenAIProvider` constructs full URL from base URL + endpoint
- Introduce `TransportFactory` closure for testable, scheme-agnostic transport construction
- `OpenAIProvider.init` takes `baseURL` + `apiKey` instead of a `Transport`

## Files
| File | Action |
|------|--------|
| `Sources/julius/OpenAI/OpenAIProvider.swift` | Modify — new init, `TransportFactory`, endpoint constant |
| `Sources/julius/HTTPTransport.swift` | No changes |
| `Tests/juliusTests/OpenAIProviderTests.swift` | Modify — use new init, add URL construction test |
| `Tests/juliusTests/IntegrationTests.swift` | Modify — use new init |

## TransportFactory
```swift
typealias TransportFactory = @Sendable (URL, String?) -> Transport
```

The factory receives the full URL (base + endpoint) and the API key. It dispatches on the URL scheme to create the appropriate transport:

```swift
// Default (HTTP only for now)
{ url, apiKey in HTTPTransport(url: url, apiKey: apiKey) }

// Future: scheme dispatch
{ url, apiKey in
    switch url.scheme {
    case "https", "http": HTTPTransport(url: url, apiKey: apiKey)
    case "wss", "ws": WebSocketTransport(url: url, apiKey: apiKey)
    default: fatalError("Unsupported scheme: \(url.scheme ?? "nil")")
    }
}
```

Tests inject a capturing factory that records the URL for assertion.

## OpenAIProvider changes
```swift
final class OpenAIProvider: Provider {
    static let endpoint = "/chat/completions"
    private let baseURL: URL
    private let apiKey: String?
    private let makeTransport: TransportFactory
    private let configuration: OpenAIConfiguration

    init(
        baseURL: URL,
        apiKey: String? = nil,
        configuration: OpenAIConfiguration = .init(),
        makeTransport: @escaping TransportFactory = { url, key in
            HTTPTransport(url: url, apiKey: key)
        }
    )
}
```

- `send()` constructs full URL via `baseURL.appendingPathComponent(Self.endpoint)`, calls `makeTransport(fullURL, apiKey)` to get a transport, then `transport.send(data)` as before.
- The provider is scheme-agnostic — it just appends its endpoint to whatever base URL it receives. The factory decides the transport based on scheme.
- `endpoint` is a static constant — future providers (Anthropic, etc.) would have their own.

## Implementation

### Test strategy
1. **URL construction** — Use a capturing `TransportFactory` that records the URL. Call `provider.send()`, verify the captured URL is `baseURL + /chat/completions`.

2. **Existing tests** — Updated to use new init. `MockTransport` injected via `makeTransport` parameter (ignoring URL/apiKey args).

3. **API key forwarded** — Capturing factory verifies `apiKey` is passed through correctly.

## Acceptance criteria
- [ ] `mise run build` passes
- [ ] Provider constructs correct full URL from base + endpoint
- [ ] API key is forwarded to transport factory
- [ ] All existing tests pass with new init
- [ ] `HTTPTransport` is unchanged
