import CTreeSitterBash

/// Validates bash commands using tree-sitter-bash parse checking.
/// Delegates to `TreeSitterBridge` which owns the underlying `TSParser*`
/// and handles cleanup via its own `deinit`.
/// Conforms to `Sendable` via `@unchecked Sendable` since the underlying C pointer
/// is not thread-safe but will be used from a single concurrency domain.
public final class BashValidator: @unchecked Sendable {
    private let bridge: TreeSitterBridge

    public init() {
        bridge = TreeSitterBridge { parser in
            ts_parser_set_language(parser, tree_sitter_bash())
        }
    }

    /// Parse a bash command string and return validation result.
    public func validate(_ command: String) -> BashValidationResult {
        guard !command.isEmpty else {
            return .valid
        }

        return bridge.withTree(command) { tree in
            if TreeSitterBridge.hasErrors(in: tree) {
                let errorInfos = TreeSitterBridge.collectErrors(in: tree)
                let errors = errorInfos.map { info in
                    ParseError(message: info.message, line: info.line, column: info.column)
                }
                return .invalid(errors: errors)
            }
            return .valid
        } ?? .invalid(errors: [
            ParseError(message: "failed to parse command", line: 0, column: 0),
        ])
    }
}

/// Result of validating a bash command through tree-sitter parsing.
public enum BashValidationResult: Equatable, Sendable {
    case valid
    case invalid(errors: [ParseError])
}

/// A single parse error detected by tree-sitter.
public struct ParseError: Equatable, Sendable {
    public var message: String
    public var line: Int
    public var column: Int
}
