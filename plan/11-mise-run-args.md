# 11 — Pass CLI arguments through `mise run dev`

## Status: done

## Depends on
10 (ArgumentParser Refactor)

## Problem
`mise run dev` runs `swift run` without specifying a target executable.
Because no target is named, there is nothing to forward arguments to —
`swift run` just builds and exits. Users must invoke the binary directly.

## Scope
Update the `dev` mise task to name the `dogpack` target so arguments flow
through.

## Files
| File | Action |
|------|--------|
| `trunk/mise.toml` | Modify — change `swift run` to `swift run dogpack` in `tasks.dev` |

## Fix

```toml
# Before
run = "swift run"

# After
run = "swift run dogpack"
```

With the target named, `mise run dev -- --url ... --api-key ... --model ...`
correctly becomes `swift run dogpack --url ... --api-key ... --model ...`.

## Acceptance criteria
- [x] `mise run dev -- --url ... --api-key ... --model ...` forwards all flags to `dogpack`
- [x] `mise run dev -- --help` prints ArgumentParser help
- [x] `mise run dev` without args still fails with the expected missing-argument error
