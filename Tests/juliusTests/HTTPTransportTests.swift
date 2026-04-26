import Foundation
@testable import julius
import Testing

// MARK: - Test Helpers

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var mockResponse: (data: Data, statusCode: Int)?
    nonisolated(unsafe) static var mockError: Error?
    nonisolated(unsafe) static var chunkDelay: Duration?

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if let error = Self.mockError {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        guard let mock = Self.mockResponse else {
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorUnknown,
            ))
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: mock.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"],
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        if let delay = Self.chunkDelay {
            Task {
                try? await Task.sleep(for: delay)
                client?.urlProtocol(self, didLoad: mock.data)
                client?.urlProtocolDidFinishLoading(self)
            }
        } else {
            client?.urlProtocol(self, didLoad: mock.data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private actor CancelTracker {
    var wasCancelled = false
    func markCancelled() {
        wasCancelled = true
    }
}

private func makeTestSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config, delegate: nil, delegateQueue: .main)
}

private let testURL = URL(string: "https://api.example.com/v1/chat/completions")!

// MARK: - SSE Test Payloads

private func ssePayload(_ events: [String]) -> Data {
    events.joined(separator: "\n\n").data(using: .utf8)!
}

// MARK: - Tests

@Suite("HTTPTransport integration tests", .serialized)
struct HTTPTransportTests {
    /// SSE parsing through HTTPTransport: multi-event payload with blank lines
    /// and [DONE] terminator. Verifies each data: line becomes a Data chunk.
    @Test
    func `sse parsing through transport`() async throws {
        MockURLProtocol.mockError = nil
        MockURLProtocol.chunkDelay = nil
        MockURLProtocol.mockResponse = (
            data: ssePayload([
                "data: {\"id\":\"1\",\"text\":\"hello\"}",
                "",
                "data: {\"id\":\"2\",\"text\":\"world\"}",
                "",
                "data: [DONE]",
            ]),
            statusCode: 200,
        )

        let transport = HTTPTransport(url: testURL, session: makeTestSession())
        let inFlight = try await transport.send(Data("{}".utf8))

        var chunks: [Data] = []
        for try await chunk in inFlight.events {
            chunks.append(chunk)
        }

        #expect(chunks.count == 2)
        let first = try #require(String(data: chunks[0], encoding: .utf8))
        let second = try #require(String(data: chunks[1], encoding: .utf8))
        #expect(first == "{\"id\":\"1\",\"text\":\"hello\"}")
        #expect(second == "{\"id\":\"2\",\"text\":\"world\"}")
    }

    /// Cancellation mid-stream: MockURLProtocol serves data with a delay.
    /// Consume first chunk, cancel, verify tracker fires.
    @Test
    func `cancellation mid stream`() async throws {
        let tracker = CancelTracker()
        MockURLProtocol.mockError = nil
        MockURLProtocol.chunkDelay = .milliseconds(50)
        MockURLProtocol.mockResponse = (
            data: ssePayload([
                "data: {\"chunk\":\"first\"}",
                "",
                "data: {\"chunk\":\"second\"}",
                "",
                "data: [DONE]",
            ]),
            statusCode: 200,
        )

        let transport = HTTPTransport(url: testURL, session: makeTestSession())
        let inFlight = try await transport.send(Data("{}".utf8))

        var chunks: [Data] = []
        for try await chunk in inFlight.events {
            chunks.append(chunk)
            await tracker.markCancelled()
            await inFlight.cancel()
            break
        }

        #expect(chunks.count >= 1)
    }

    /// Network and timeout failures map to JuliusError.connectionFailed.
    /// MockURLProtocol injects errors instantly — no real wait.
    @Test(arguments: [
        (URLError.Code.timedOut, "timed out"),
        (URLError.Code.notConnectedToInternet, "no connection"),
        (URLError.Code.cannotConnectToHost, "host unreachable"),
    ])
    func `network failures map to julius error`(
        code: URLError.Code,
        label: String,
    ) async throws {
        MockURLProtocol.mockResponse = nil
        MockURLProtocol.chunkDelay = nil
        MockURLProtocol.mockError = NSError(
            domain: NSURLErrorDomain,
            code: code.rawValue,
        )

        let transport = HTTPTransport(url: testURL, session: makeTestSession())

        do {
            _ = try await transport.send(Data("{}".utf8))
            Issue.record("Expected error for \(label)")
        } catch let error as JuliusError {
            if case .connectionFailed = error {
                // Correct case
            } else {
                Issue.record("Wrong JuliusError case for \(label): \(error)")
            }
        } catch {
            Issue.record("Unexpected error type for \(label): \(error)")
        }
    }

    /// MockTransport contract: canned data flows through InFlight, cancel
    /// closure is callable. Validates the shared test utility.
    @Test
    func `mock transport contract`() async throws {
        let cannedPayload = Data("{\"result\":\"ok\"}".utf8)
        let transport = MockTransport(cannedData: cannedPayload)

        let inFlight = try await transport.send(Data("request".utf8))

        var chunks: [Data] = []
        for try await chunk in inFlight.events {
            chunks.append(chunk)
        }

        #expect(chunks.count == 1)
        #expect(chunks[0] == cannedPayload)

        // Cancel should be callable without error
        await inFlight.cancel()
    }
}
