import Foundation

public protocol Session: Sendable {
    func messages() async -> [Message]
    func append(_ message: Message) async throws
}
