import Foundation
import os

nonisolated struct AutomationRunContext: Sendable {
    let automationID: String
    let runID: String
}

nonisolated enum AutomationRunScope {
    @TaskLocal static var current: AutomationRunContext?
}

nonisolated struct AutomationRunSummary: Identifiable, Sendable {
    let id: String
    let automationID: String
    let name: String
    let instruction: String
    let intervalSeconds: Int
    let schedule: String?
    let startedAt: Date
    let endedAt: Date?
    let status: String
}

nonisolated struct AutomationLogEntry: Identifiable, Sendable {
    let id: Int
    let kind: String
    let timestamp: Date?
    let text: String
}

/// Append-only JSONL log of every LLM wire interaction and tool call. Normal
/// chat uses one file per day; automation traffic uses one file per run so it
/// can be browsed and cleared independently. Failures never break chat.
actor LLMLog {
    static let shared = LLMLog()

    private let directory: URL
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    private let displayEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    // Formatters are costly to build; actor isolation makes reuse safe.
    private let timestampFormatter = ISO8601DateFormatter()
    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    init(directory: URL? = nil) {
        self.directory = directory ?? {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            return base.appendingPathComponent("electragne/logs", isDirectory: true)
        }()
    }

    func append(kind: String, _ fields: [String: ChatToolValue]) {
        var entry = fields
        entry["kind"] = .string(kind)
        entry["ts"] = .string(timestampFormatter.string(from: Date()))
        let run = AutomationRunScope.current
        if let run {
            entry["automationID"] = .string(run.automationID)
            entry["runID"] = .string(run.runID)
        }
        do {
            let url = run.map(runFileURL) ?? fileURL(for: Date())
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var line = try encoder.encode(entry)
            line.append(0x0A)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            // ponytail: opens the file per entry; cache a handle if chat volume ever matters.
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            Log.llm.error("Failed to append log entry: \(error.localizedDescription)")
        }
    }

    func fileURL(for date: Date) -> URL {
        directory.appendingPathComponent("llm-\(dayFormatter.string(from: date)).jsonl")
    }

    func automationRuns() -> [AutomationRunSummary] {
        let root = automationDirectory
        guard let automationFolders = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }

        return automationFolders.flatMap { folder in
            (try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )) ?? []
        }
        .compactMap(runSummary)
        .sorted { $0.startedAt > $1.startedAt }
    }

    func automationEntries(automationID: String, runID: String) -> [AutomationLogEntry] {
        decodedLines(at: runFileURL(.init(automationID: automationID, runID: runID)))
            .enumerated()
            .compactMap { offset, entry in
                guard let data = try? displayEncoder.encode(entry),
                      let text = String(data: data, encoding: .utf8) else { return nil }
                return AutomationLogEntry(
                    id: offset,
                    kind: entry["kind"]?.stringValue ?? "entry",
                    timestamp: entry["ts"]?.stringValue.flatMap(timestampFormatter.date(from:)),
                    text: text
                )
            }
    }

    func clearAutomationHistory(_ automationID: String) throws {
        let url = automationDirectory.appendingPathComponent(automationID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private var automationDirectory: URL {
        directory.appendingPathComponent("automations", isDirectory: true)
    }

    private func runFileURL(_ run: AutomationRunContext) -> URL {
        automationDirectory
            .appendingPathComponent(run.automationID, isDirectory: true)
            .appendingPathComponent("\(run.runID).jsonl")
    }

    private func decodedLines(at url: URL) -> [[String: ChatToolValue]] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { try? JSONDecoder().decode([String: ChatToolValue].self, from: Data($0.utf8)) }
    }

    private func runSummary(at url: URL) -> AutomationRunSummary? {
        let entries = decodedLines(at: url)
        guard let start = entries.first(where: { $0["kind"]?.stringValue == "automation_run_start" }),
              let automationID = start["automationID"]?.stringValue,
              let runID = start["runID"]?.stringValue,
              let name = start["name"]?.stringValue,
              let instruction = start["instruction"]?.stringValue,
              let interval = start["intervalSeconds"]?.numberValue,
              let timestamp = start["ts"]?.stringValue,
              let startedAt = timestampFormatter.date(from: timestamp) else { return nil }
        let end = entries.last(where: { $0["kind"]?.stringValue == "automation_run_end" })
        return AutomationRunSummary(
            id: runID,
            automationID: automationID,
            name: name,
            instruction: instruction,
            intervalSeconds: Int(interval),
            schedule: start["schedule"]?.stringValue,
            startedAt: startedAt,
            endedAt: end?["ts"]?.stringValue.flatMap(timestampFormatter.date(from:)),
            status: end?["status"]?.stringValue ?? "interrupted"
        )
    }
}

/// Decorates a ChatHTTPTransport, logging every request body and full
/// response (streaming responses reassembled) to an LLMLog. API keys travel
/// only in headers, which are deliberately never logged.
nonisolated struct LoggingTransport: ChatHTTPTransport {
    let base: any ChatHTTPTransport
    let log: LLMLog

    init(
        base: any ChatHTTPTransport = URLSessionTransport(session: .shared),
        log: LLMLog = .shared
    ) {
        self.base = base
        self.log = log
    }

    /// Transport routed through the Tailscale SOCKS5 proxy when `proxied`.
    init(proxied: Bool) {
        self.init(base: URLSessionTransport(session: SOCKSProxy.urlSession(proxied: proxied)))
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let id = UUID().uuidString
        await log.append(kind: "request", Self.requestFields(id: id, request: request))
        do {
            let (data, response) = try await base.data(for: request)
            await log.append(kind: "response", Self.responseFields(
                id: id,
                response: response,
                body: String(decoding: data, as: UTF8.self)
            ))
            return (data, response)
        } catch {
            await log.append(kind: "error", [
                "id": .string(id),
                "message": .string(error.localizedDescription),
            ])
            throw error
        }
    }

    func lines(for request: URLRequest) async throws
        -> (AsyncThrowingStream<String, Error>, URLResponse) {
        let id = UUID().uuidString
        await log.append(kind: "request", Self.requestFields(id: id, request: request))
        let inner: AsyncThrowingStream<String, Error>
        let response: URLResponse
        do {
            (inner, response) = try await base.lines(for: request)
        } catch {
            await log.append(kind: "error", [
                "id": .string(id),
                "message": .string(error.localizedDescription),
            ])
            throw error
        }
        let log = log
        let stream = AsyncThrowingStream<String, Error>.fromTask { continuation in
            var collected: [String] = []
            do {
                for try await line in inner {
                    collected.append(line)
                    continuation.yield(line)
                }
                await log.append(kind: "response", Self.responseFields(
                    id: id,
                    response: response,
                    body: collected.joined(separator: "\n")
                ))
            } catch {
                await log.append(kind: "error", [
                    "id": .string(id),
                    "message": .string(error.localizedDescription),
                    "partialBody": .string(collected.joined(separator: "\n")),
                ])
                throw error
            }
        }
        return (stream, response)
    }

    private static func requestFields(id: String, request: URLRequest) -> [String: ChatToolValue] {
        [
            "id": .string(id),
            "method": .string(request.httpMethod ?? "GET"),
            "url": .string(request.url?.absoluteString ?? ""),
            "body": .string(request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""),
        ]
    }

    private static func responseFields(
        id: String,
        response: URLResponse,
        body: String
    ) -> [String: ChatToolValue] {
        [
            "id": .string(id),
            "status": .number(Double((response as? HTTPURLResponse)?.statusCode ?? 0)),
            "body": .string(body),
        ]
    }
}
