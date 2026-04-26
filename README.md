# Dogpack

A distributed agentic coding system that comes with its own harness.

## Development

```
mise run build    # format → lint → build universal binary
mise run dev      # build and run (quick iteration)
```

## Contributing

Commits should follow the [Conventional Commits](https://www.conventionalcommits.org/) specification.

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

