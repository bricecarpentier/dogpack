import Foundation
import julius
import Testing
import zoomies

// MARK: - BashValidator Tests

@Suite("BashValidator tests")
struct BashValidatorTests {
    /// Valid simple commands pass validation.
    @Test
    func `valid simple commands`() {
        let validator = BashValidator()

        #expect(validator.validate("echo hello") == .valid)
        #expect(validator.validate("ls -la /tmp") == .valid)
        #expect(validator.validate("cat file.txt | grep pattern") == .valid)
        #expect(validator.validate("export FOO=bar") == .valid)
    }

    /// Empty commands are treated as valid (no execution needed).
    @Test
    func `empty command is valid`() {
        let validator = BashValidator()
        #expect(validator.validate("") == .valid)
    }

    /// Invalid syntax is detected and reported with line/column info.
    @Test
    func `invalid syntax detected`() {
        let validator = BashValidator()

        // Incomplete if statement
        let result = validator.validate("if true")
        if case let .invalid(errors) = result {
            #expect(!errors.isEmpty)
            #expect(errors.allSatisfy { $0.line > 0 && $0.column > 0 })
        } else {
            Issue.record("Expected .invalid for incomplete if statement, got \(result)")
        }
    }

    /// Complex valid commands pass validation.
    @Test
    func `complex valid commands`() {
        let validator = BashValidator()

        #expect(validator.validate("for i in 1 2 3; do echo $i; done") == .valid)
        #expect(validator.validate("if [ -f file ]; then cat file; fi") == .valid)
        #expect(validator.validate("function greet() { echo hello; }") == .valid)
    }

    /// Genuinely broken syntax is caught.
    @Test
    func `broken syntax rejected`() {
        let validator = BashValidator()

        let result = validator.validate(")")
        if case .invalid = result {
            // expected
        } else {
            Issue.record("Expected .invalid for bare ')', got \(result)")
        }
    }
}

// MARK: - BashTool Integration Tests

@Suite("BashTool integration tests")
struct BashToolTests {
    /// BashTool conforms to Tool with the correct definition.
    @Test
    func `tool definition`() {
        let tool = BashTool()
        #expect(tool.definition.name == "bash")
        #expect(tool.definition.description.contains("bash"))
    }

    /// Valid command is executed and produces stdout output.
    @Test
    func `valid command executes`() async throws {
        let tool = BashTool()
        let call = ToolCall(id: "c1", name: "bash", arguments: #"{"command": "echo hello"}"#)
        let result = try await tool.execute(call)

        #expect(result.callId == "c1")
        #expect(result.output.contains("hello"))
    }

    /// Invalid syntax is rejected before execution with parse error details.
    @Test
    func `invalid syntax rejected without execution`() async throws {
        let tool = BashTool()
        let call = ToolCall(
            id: "c2",
            name: "bash",
            arguments: #"{"command": "if true then echo hi"}"#,
        )
        let result = try await tool.execute(call)

        #expect(result.callId == "c2")
        #expect(result.output.contains("Syntax validation failed"))
        // Should NOT contain actual command output
        #expect(!result.output.contains("hi"))
    }

    /// Missing command argument returns error.
    @Test
    func `missing command argument`() async throws {
        let tool = BashTool()
        let call = ToolCall(id: "c3", name: "bash", arguments: "{}")
        let result = try await tool.execute(call)

        #expect(result.output.contains("missing"))
    }

    /// Failed command returns stderr and exit code.
    @Test
    func `failed command returns error`() async throws {
        let tool = BashTool()
        let call = ToolCall(
            id: "c4",
            name: "bash",
            arguments: #"{"command": "ls /nonexistent_directory_xyz"}"#,
        )
        let result = try await tool.execute(call)

        #expect(result.callId == "c4")
        #expect(result.output.contains("exit code:"))
    }

    /// Command allowlist blocks unauthorized commands.
    @Test
    func `allowlist blocks unauthorized`() async throws {
        let tool = BashTool(allowedCommands: ["echo"])
        let call = ToolCall(
            id: "c5",
            name: "bash",
            arguments: #"{"command": "rm -rf /"}"#,
        )
        let result = try await tool.execute(call)

        #expect(result.output.contains("not in the allowed list"))
    }

    /// Command allowlist allows authorized commands.
    @Test
    func `allowlist allows authorized`() async throws {
        let tool = BashTool(allowedCommands: ["echo"])
        let call = ToolCall(
            id: "c6",
            name: "bash",
            arguments: #"{"command": "echo allowed"}"#,
        )
        let result = try await tool.execute(call)

        #expect(result.output.contains("allowed"))
    }

    /// Working directory is respected during execution.
    @Test
    func `working directory respected`() async throws {
        let tmpDir = NSTemporaryDirectory()
        let tool = BashTool(workingDirectory: tmpDir)
        let call = ToolCall(
            id: "c7",
            name: "bash",
            arguments: #"{"command": "pwd"}"#,
        )
        let result = try await tool.execute(call)

        #expect(result.output.contains(tmpDir.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
    }

    /// Multi-line commands work correctly.
    @Test
    func `multi line command`() async throws {
        let tool = BashTool()
        let call = ToolCall(
            id: "c8",
            name: "bash",
            arguments: #"{"command": "echo line1\necho line2"}"#,
        )
        let result = try await tool.execute(call)

        #expect(result.output.contains("line1"))
        #expect(result.output.contains("line2"))
    }
}

// MARK: - BashTool + ToolRegistry Integration

@Suite("BashTool registry integration tests")
struct BashToolRegistryTests {
    /// BashTool can be registered and dispatched through ToolRegistry.
    @Test
    func `registry dispatch`() async throws {
        let registry = ToolRegistry()
        try await registry.register(BashTool())

        let defs = await registry.definitions
        #expect(defs.contains { $0.name == "bash" })

        let call = ToolCall(
            id: "r1",
            name: "bash",
            arguments: #"{"command": "echo from-registry"}"#,
        )
        let result = try await registry.execute(call)
        #expect(result.output.contains("from-registry"))
    }
}
