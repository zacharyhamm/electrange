import Foundation
import os

/// Append-only JSONL log of every LLM wire interaction and tool call, one
/// file per day under Application Support/electragne/logs. Always on; failures
/// are swallowed so logging can never break chat.
actor LLMLog {
    static let shared = LLMLog()

    private let directory: URL
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
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
        entry["ts"] = .string(ISO8601DateFormatter().string(from: Date()))
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            var line = try encoder.encode(entry)
            line.append(0x0A)
            let url = fileURL(for: Date())
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
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return directory.appendingPathComponent("llm-\(formatter.string(from: date)).jsonl")
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
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
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
                    continuation.finish()
                } catch {
                    await log.append(kind: "error", [
                        "id": .string(id),
                        "message": .string(error.localizedDescription),
                        "partialBody": .string(collected.joined(separator: "\n")),
                    ])
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
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
