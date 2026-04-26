import Foundation
@testable import julius
import Testing

struct SessionFactory {
    let make: @Sendable () -> any Session
    let name: String
}

private let sessionFactories: [SessionFactory] = [
    .init(make: { InMemorySession() }, name: "InMemory"),
    // Future: .init(make: { SQLiteSession() }, name: "SQLite"),
]

@Suite("Session implementations tests")
struct SessionImplementationsTests {
    @Test(arguments: sessionFactories)
    func `empty session returns no messages`(factory: SessionFactory) async {
        let session = factory.make()
        let messages = await session.messages()
        #expect(messages.isEmpty)
    }

    @Test(arguments: sessionFactories)
    func `appended messages are returned in order`(factory: SessionFactory) async throws {
        let session = factory.make()
        try await session.append(.user("hello"))
        try await session.append(.assistant(
            AssistantMessage(content: [.text("hi there")], stopReason: .stop),
        ))

        let messages = await session.messages()
        #expect(messages.count == 2)

        guard case let .user(text) = messages[0] else {
            Issue.record("Expected user message at index 0"); return
        }
        #expect(text == "hello")

        guard case let .assistant(msg) = messages[1] else {
            Issue.record("Expected assistant message at index 1"); return
        }
        #expect(msg.content == [.text("hi there")])
        #expect(msg.stopReason == .stop)
    }

    @Test(arguments: sessionFactories)
    func `concurrent appends are safe`(factory: SessionFactory) async throws {
        let session = factory.make()
        async let userTask: Void = session.append(.user("hello"))
        async let assistantTask: Void = session.append(.assistant(
            AssistantMessage(content: [.text("hi there")], stopReason: .stop),
        ))
        _ = try await (userTask, assistantTask)

        let messages = await session.messages()
        #expect(messages.count == 2)

        let hasUser = messages.contains { if case .user("hello") = $0 { true } else { false } }
        let hasAssistant = messages.contains {
            if case let .assistant(msg) = $0, msg.content == [.text("hi there")] { true } else { false }
        }
        #expect(hasUser)
        #expect(hasAssistant)
    }
}
