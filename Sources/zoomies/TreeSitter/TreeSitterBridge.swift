import CTreeSitter

/// Shared Swift wrapper for the tree-sitter C API.
/// Provides a Swift-friendly interface for parser creation, parsing, and error node traversal.
/// Used by all tree-sitter validators (BashValidator, future LuaValidator, etc.).
///
/// Actor-isolated to prevent concurrent access to the underlying `TSParser*`,
/// which is not thread-safe. The tree pointer is never exposed outside the actor —
/// `withTree` runs the caller's body inline and deletes the tree before returning.
public actor TreeSitterBridge {
    /// Wrapper to allow deinit on a non-Sendable C pointer from an actor's
    /// nonisolated deinit. Safe because deinit only runs after all references
    /// to the actor are gone, so no concurrent access is possible.
    private final class ParserHandle: @unchecked Sendable {
        let pointer: OpaquePointer
        init(_ pointer: OpaquePointer) {
            self.pointer = pointer
        }

        deinit { ts_parser_delete(pointer) }
    }

    private let parser: ParserHandle

    /// Create a bridge with a parser, calling the setup closure to configure the language.
    /// The closure receives the parser pointer so callers can call `ts_parser_set_language` directly.
    public init(_ setup: (OpaquePointer) -> Void) {
        guard let rawParser = ts_parser_new() else {
            fatalError("ts_parser_new() failed: out of memory")
        }
        setup(rawParser)
        parser = ParserHandle(rawParser)
    }

    /// Parse a string and execute the closure with the resulting syntax tree.
    /// The tree is deleted automatically when the closure returns — the pointer
    /// must not escape. Returns nil if parsing fails to produce a tree.
    public func withTree<R: Sendable>(_ input: String, _ body: (OpaquePointer) throws -> R) rethrows -> R? {
        let tree = input.withCString { ptr -> OpaquePointer? in
            ts_parser_parse_string(parser.pointer, nil, ptr, UInt32(input.utf8.count))
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

    /// Collect all command names from a syntax tree, extracting their text
    /// from the source string. Traverses the full tree to find `command_name`
    /// nodes in pipelines, lists, subshells, and command substitutions.
    public static func collectCommandNames(in tree: OpaquePointer, source: String) -> [String] {
        let root = ts_tree_root_node(tree)
        return collectCommandNames(from: root, source: source)
    }

    private static func collectCommandNames(from node: TSNode, source: String) -> [String] {
        guard let nodeType = ts_node_type(node) else { return [] }
        let typeStr = String(cString: nodeType)

        // When we find a command_name, extract its text from the source
        if typeStr == "command_name" {
            let start = ts_node_start_byte(node)
            let end = ts_node_end_byte(node)
            let startIndex = source.index(source.startIndex, offsetBy: Int(start))
            let endIndex = source.index(source.startIndex, offsetBy: Int(end))
            let name = String(source[startIndex ..< endIndex]).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? [] : [name]
        }

        // Recurse into children
        var names: [String] = []
        let childCount = ts_node_child_count(node)
        for index in 0 ..< childCount {
            let child = ts_node_child(node, UInt32(index))
            names.append(contentsOf: collectCommandNames(from: child, source: source))
        }
        return names
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
