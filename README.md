# Dogpack

A distributed agentic coding system that comes with its own harness.

## Development

```
mise run build    # format → lint → build universal binary
mise run dev      # build and run (quick iteration)
```

## Contributing

Commits should follow the [Conventional Commits](https://www.conventionalcommits.org/) specification.

When changes are confined to a specific area of the codebase, the scope is mandatory (e.g. `feat(julius):`, `fix(dogpack):`). Omit the scope only when the change genuinely spans multiple areas — `docs:` is a type, not a scope, so a README change touching no module-specific code does not need one.

All contributions must pass both build and tests:

```
mise run build    # must exit successfully
mise run test     # must exit successfully
```

Code is automatically formatted and linted as part of `mise run build`. You can also run them directly:

```
mise run format   # format with swiftformat
mise run lint     # lint with swiftlint
```

