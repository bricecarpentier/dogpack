import Foundation

public protocol Transport: Sendable {
    func connect() async throws
    func send(_ data: Data) async throws -> InFlight
    func disconnect() async
}
