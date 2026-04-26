import Foundation
@testable import julius

final class MockTransport: Transport, @unchecked Sendable {
    private let cannedData: Data

    init(cannedData: Data) {
        self.cannedData = cannedData
    }

    func connect() async throws {
        // No-op for mock
    }

    func send(_: Data) async throws -> InFlight {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let canned = cannedData
        continuation.yield(canned)
        continuation.finish()
        return InFlight(
            events: stream,
            cancel: {},
        )
    }

    func disconnect() async {
        // No-op for mock
    }
}
