import CTreeSitterBash

/// Validates bash commands using tree-sitter-bash parse checking.
/// Delegates to `TreeSitterBridge` which serializes access to the
/// underlying `TSParser*` via actor isolation.
public final class BashValidator: Sendable {
    private let bridge: TreeSitterBridge

    public init() {
        bridge = TreeSitterBridge { parser in
            ts_parser_set_language(parser, tree_sitter_bash())
        }
    }

    /// Parse a bash command string and return validation result.
    public func validate(_ command: String) async -> BashValidationResult {
        guard !command.isEmpty else {
            return .valid
        }

        return await bridge.withTree(command) { tree in
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

    /// Extract all command names from a bash command string via tree-sitter AST traversal.
    /// Finds every `command_name` node including those in pipelines, lists, subshells,
    /// and command substitutions. Returns an empty array if parsing fails.
    public func extractCommandNames(_ command: String) async -> [String] {
        guard !command.isEmpty else {
            return []
        }

        return await bridge.withTree(command) { tree in
            TreeSitterBridge.collectCommandNames(in: tree, source: command)
        } ?? []
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
