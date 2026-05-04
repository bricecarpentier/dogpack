import CTreeSitter

/// Shared Swift wrapper for the tree-sitter C API.
/// Provides a Swift-friendly interface for parser creation, parsing, and error node traversal.
/// Used by all tree-sitter validators (BashValidator, future LuaValidator, etc.).
public final class TreeSitterBridge: @unchecked Sendable {
    private(set) var parser: OpaquePointer

    /// Create a bridge with a parser, calling the setup closure to configure the language.
    /// The closure receives the parser pointer so callers can call `ts_parser_set_language` directly.
    public init(_ setup: (OpaquePointer) -> Void) {
        parser = ts_parser_new()
        setup(parser)
    }

    deinit {
        ts_parser_delete(parser)
    }

    /// Parse a string and execute the closure with the resulting syntax tree.
    /// The tree is deleted automatically when the closure returns — the pointer
    /// must not escape. Returns nil if parsing fails to produce a tree.
    public func withTree<R>(_ input: String, _ body: (OpaquePointer) throws -> R) rethrows -> R? {
        var tree: OpaquePointer?
        input.withCString { ptr in
            tree = ts_parser_parse_string(parser, nil, ptr, UInt32(input.utf8.count))
        }
        guard let tree else { return nil }
        defer { ts_tree_delete(tree) }
        return try body(tree)
    }

    /// Check if a tree contains any error nodes starting from the root.
    public static func hasErrors(in tree: OpaquePointer) -> Bool {
        let root = ts_tree_root_node(tree)
        return ts_node_has_error(root)
    }

    /// Collect all error nodes from a syntax tree, returning their positions and messages.
    public static func collectErrors(in tree: OpaquePointer) -> [ParseErrorInfo] {
        let root = ts_tree_root_node(tree)
        return collectErrors(from: root)
    }

    /// Recursively collect error nodes starting from a given node.
    private static func collectErrors(from node: TSNode) -> [ParseErrorInfo] {
        var errors: [ParseErrorInfo] = []

        if ts_node_is_error(node) {
            let startPoint = ts_node_start_point(node)
            let error = ParseErrorInfo(
                message: errorContext(for: node),
                line: Int(startPoint.row) + 1,
                column: Int(startPoint.column) + 1,
            )
            errors.append(error)
        }

        let childCount = ts_node_child_count(node)
        for index in 0 ..< childCount {
            let child = ts_node_child(node, UInt32(index))
            errors.append(contentsOf: collectErrors(from: child))
        }

        return errors
    }

    /// Extract context around an error node for a meaningful message.
    private static func errorContext(for node: TSNode) -> String {
        guard let type = ts_node_type(node) else {
            return "syntax error"
        }
        let typeStr = String(cString: type)
        return "syntax error near \(typeStr)"
    }
}

/// Information about a parse error found in a syntax tree.
public struct ParseErrorInfo: Equatable, Sendable {
    public var message: String
    public var line: Int
    public var column: Int
}
