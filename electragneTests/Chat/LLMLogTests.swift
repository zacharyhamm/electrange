import Foundation
import Testing
@testable import electragne

struct LLMLogTests {
    private func makeLog() -> (LLMLog, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmlog-tests-\(UUID().uuidString)", isDirectory: true)
        return (LLMLog(directory: dir), dir)
    }

    private func entries(in log: LLMLog) async throws -> [[String: ChatToolValue]] {
        let url = await log.fileURL(for: Date())
        let data = try Data(contentsOf: url)
        return try String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { try JSONDecoder().decode([String: ChatToolValue].self, from: Data($0.utf8)) }
    }

    @Test func logsRequestAndReassembledStreamingResponse() async throws {
        let (log, dir) = makeLog()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = StubChatHTTPTransport([
            .init(lines: [#"{"a":1}"#, #"{"b":2}"#]),
        ])
        let transport = LoggingTransport(base: stub, log: log)

        var request = URLRequest(url: URL(string: "http://localhost:1234/chat")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"m"}"#.utf8)

        let (stream, _) = try await transport.lines(for: request)
        var received: [String] = []
        for try await line in stream { received.append(line) }
        #expect(received == [#"{"a":1}"#, #"{"b":2}"#])

        let logged = try await entries(in: log)
        #expect(logged.count == 2)
        #expect(logged[0]["kind"] == .string("request"))
        #expect(logged[0]["body"] == .string(#"{"model":"m"}"#))
        #expect(logged[0]["url"] == .string("http://localhost:1234/chat"))
        #expect(logged[1]["kind"] == .string("response"))
        #expect(logged[1]["status"] == .number(200))
        #expect(logged[1]["body"] == .string("{\"a\":1}\n{\"b\":2}"))
        #expect(logged[1]["id"] == logged[0]["id"])
    }

    @Test func logsNonStreamingResponseAndErrors() async throws {
        let (log, dir) = makeLog()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = StubChatHTTPTransport([
            .init(data: Data(#"{"ok":true}"#.utf8)),
            .init(error: URLError(.notConnectedToInternet)),
        ])
        let transport = LoggingTransport(base: stub, log: log)
        let request = URLRequest(url: URL(string: "http://localhost:1234/models")!)

        _ = try await transport.data(for: request)
        await #expect(throws: URLError.self) {
            _ = try await transport.data(for: request)
        }

        let logged = try await entries(in: log)
        #expect(logged.map { $0["kind"] } == [
            .string("request"), .string("response"), .string("request"), .string("error"),
        ])
        #expect(logged[1]["body"] == .string(#"{"ok":true}"#))
    }
}
