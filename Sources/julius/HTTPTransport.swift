import Foundation

final class HTTPTransport: Transport, @unchecked Sendable {
    private let url: URL
    private let session: URLSession

    init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    func connect() async throws {
        // HTTP is stateless — no-op
    }

    func send(_ data: Data) async throws -> InFlight {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw JuliusError.connectionFailed(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw JuliusError.connectionFailed("Non-HTTP response")
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw try await httpError(statusCode: httpResponse.statusCode, bytes: bytes)
        }

        return makeSSEStream(from: bytes)
    }

    private func httpError(
        statusCode: Int,
        bytes: URLSession.AsyncBytes,
    ) async throws -> JuliusError {
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            if body.count >= 1024 { break }
        }
        let detail = String(data: body, encoding: .utf8) ?? ""
        return JuliusError.connectionFailed("HTTP \(statusCode): \(detail)")
    }

    private func makeSSEStream(
        from bytes: URLSession.AsyncBytes,
    ) -> InFlight {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()

        let task = Task {
            for try await line in bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                guard trimmed.hasPrefix("data:") else { continue }

                let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }

                guard let data = payload.data(using: .utf8) else {
                    continuation.finish(
                        throwing: JuliusError.responseParsingFailed(
                            "Invalid UTF-8 in SSE payload",
                        ),
                    )
                    return
                }
                continuation.yield(data)
            }
            continuation.finish()
        }

        return InFlight(
            events: stream,
            cancel: { task.cancel() },
        )
    }

    func disconnect() async {
        // HTTP is stateless — no-op
    }
}
