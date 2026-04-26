import Foundation
@testable import julius

final class MockTransport: Transport, @unchecked Sendable {
    private let cannedChunks: [Data]
    private let onSend: (@Sendable (Data) -> Void)?

    private(set) var lastSentData: Data?

    /// Create a mock that yields a single data chunk.
    init(cannedData: Data, onSend: (@Sendable (Data) -> Void)? = nil) {
        cannedChunks = [cannedData]
        self.onSend = onSend
    }

    /// Create a mock that yields multiple data chunks sequentially.
    init(cannedChunks: [Data], onSend: (@Sendable (Data) -> Void)? = nil) {
        self.cannedChunks = cannedChunks
        self.onSend = onSend
    }

    func connect() async throws {
        // No-op for mock
    }

    func send(_ data: Data) async throws -> InFlight {
        lastSentData = data
        onSend?(data)

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let chunks = cannedChunks
        Task {
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
        return InFlight(
            events: stream,
            cancel: {},
        )
    }

    func disconnect() async {
        // No-op for mock
    }
}
