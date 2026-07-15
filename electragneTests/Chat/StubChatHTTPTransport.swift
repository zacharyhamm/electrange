import Foundation
@testable import electragne

nonisolated final class StubChatHTTPTransport: ChatHTTPTransport, @unchecked Sendable {
    struct Reply {
        var lines: [String] = []
        var data = Data()
        var status = 200
        var error: Error?
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var capturedRequests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    var requests: [URLRequest] { lock.withLock { capturedRequests } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let reply = nextReply(for: request)
        if let error = reply.error { throw error }
        return (reply.data, response(for: request, status: reply.status))
    }

    func lines(for request: URLRequest) async throws
        -> (AsyncThrowingStream<String, Error>, URLResponse) {
        let reply = nextReply(for: request)
        let stream = AsyncThrowingStream<String, Error> { continuation in
            reply.lines.forEach { continuation.yield($0) }
            if let error = reply.error { continuation.finish(throwing: error) }
            else { continuation.finish() }
        }
        return (stream, response(for: request, status: reply.status))
    }

    private func nextReply(for request: URLRequest) -> Reply {
        lock.withLock {
            capturedRequests.append(request)
            return replies.removeFirst()
        }
    }

    private func response(for request: URLRequest, status: Int) -> URLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}
