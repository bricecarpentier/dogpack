import Foundation

actor InMemorySession: Session {
    private var store: [Message] = []

    func messages() -> [Message] {
        store
    }

    func append(_ message: Message) {
        store.append(message)
    }
}
