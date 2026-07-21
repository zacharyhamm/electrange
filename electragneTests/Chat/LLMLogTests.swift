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

    @Test func automationScopeKeepsACompleteClearableRunLog() async throws {
        let (log, dir) = makeLog()
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = AutomationRunContext(automationID: "automation-1", runID: "run-1")
        let transport = LoggingTransport(
            base: StubChatHTTPTransport([.init(lines: [#"{"answer":"NOTHING"}"#])]),
            log: log
        )

        try await AutomationRunScope.$current.withValue(context) {
            await log.append(kind: "automation_run_start", [
                "name": .string("Inbox watch"),
                "instruction": .string("Check the inbox."),
                "intervalSeconds": .number(300),
                "schedule": .string("09:00–17:00 on Mon, Tue, Wed, Thu, Fri"),
            ])
            let (lines, _) = try await transport.lines(for: URLRequest(url: URL(string: "http://localhost/chat")!))
            for try await _ in lines {}
            await log.append(kind: "tool", ["name": .string("search_gmail")])
            await log.append(kind: "automation_run_end", [
                "status": .string("completed"),
                "output": .string("NOTHING"),
                "notified": .bool(false),
            ])
        }

        let run = try #require(await log.automationRuns().first)
        #expect(run.id == "run-1")
        #expect(run.automationID == "automation-1")
        #expect(run.status == "completed")
        #expect(run.endedAt != nil)
        #expect(await log.automationEntries(automationID: "automation-1", runID: "run-1").map(\.kind) == [
            "automation_run_start", "request", "response", "tool", "automation_run_end",
        ])
        #expect(!FileManager.default.fileExists(atPath: await log.fileURL(for: Date()).path))

        try await log.clearAutomationHistory("automation-1")
        #expect(await log.automationRuns().isEmpty)
    }
}
