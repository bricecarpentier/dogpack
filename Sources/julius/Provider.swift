import Foundation

public protocol Provider: Sendable {
    func send(_ request: ProviderRequest) async throws -> ResponseStream
}
