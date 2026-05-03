import Foundation

public actor InMemorySession: Session {
    private var store: [Message] = []

    public init() {}

    public func messages() -> [Message] {
        store
    }

    public func append(_ message: Message) throws {
        store.append(message)
    }

    public func replaceMessages(_ messages: [Message]) throws {
        store = messages
    }
}
