# 08 — CLI Test Client (dogpack)

## Status: done

## Depends on
06 (Provider Endpoint Path), 07 (Loop)

## Scope
- Wire up the `dogpack` executable as a basic REPL
- CLI required options: `--url`, `--api-key`, `--model`
- Ctrl-C cancels the current request, preserves session, returns to prompt
- Reasoning blocks displayed with `| ` prefix

## Files
| File | Action |
|------|--------|
| `Package.swift` | Modify — add `julius` dependency to `dogpack` target |
| `Sources/dogpack/main.swift` | Rewrite |

## CLI
```
dogpack --url <base-url> --api-key <key> --model <model>
```
- `--url` — provider base URL up to `/v1` (e.g. `https://api.openai.com/v1`)
- `--api-key` — API key
- `--model` — model name (e.g. `gpt-4o-mini`)

## REPL behavior
1. Parse CLI options, exit with usage on missing args
2. Create `OpenAIProvider(baseURL:apiKey:)` → `InMemorySession` → `Loop`
3. Install `SIGINT` handler that cancels the current `Task`
4. Print prompt, read line from stdin
5. On EOF or `/quit` → exit
6. Append `.user(line)` to session
7. Run `loop.run()` in a `Task`
8. On `JuliusError.cancelled` — print partial response, return to prompt
9. On success — print all content blocks:
   - `.text` — printed as-is
   - `.reasoning` — prefixed with `| ` on each line
10. Repeat

## Output example
```
> Why is the sky blue?
| Let me think about light scattering...
The sky appears blue because of Rayleigh scattering...
```

## Implementation

### Test strategy
Smoke test only — verify the CLI prints usage and exits with error when args are missing. Full REPL flow is manual.

## Acceptance criteria
- [ ] `mise run build` passes
- [ ] Missing args prints usage and exits non-zero
- [ ] REPL sends user input through the loop and prints text response
- [ ] Reasoning blocks displayed with `| ` prefix
- [ ] Ctrl-C cancels current request, prints partial response, returns to prompt
- [ ] `/quit` or EOF exits cleanly
