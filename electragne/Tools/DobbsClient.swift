//
//  DobbsClient.swift
//  electragne
//
//  Minimal client for the dobbs watcher daemon's IPC protocol: newline-
//  delimited JSON over TCP. The client speaks first with a ClientHello
//  (protocol version + bearer token), the daemon answers with a hello event,
//  then requests and responses are correlated by id. Each tool call opens a
//  fresh connection, performs one RPC, and closes — no event streaming.
//

import Foundation
import Network

nonisolated struct DobbsSettings: Sendable {
    let endpoint: String // "host:port" of a dobbs daemon
    let token: String
    let workspace: String? // expected team name; verified against hello when set

    /// The Settings-window configuration, or nil until endpoint and token are set.
    static func current() -> DobbsSettings? {
        guard let endpoint = UserPreferences.dobbsEndpoint(),
              let token = ChatAPIKeyStore.load(for: .dobbs) else { return nil }
        return DobbsSettings(
            endpoint: endpoint, token: token,
            workspace: UserPreferences.dobbsWorkspace()
        )
    }
}

nonisolated enum DobbsError: LocalizedError, Equatable {
    case notConfigured
    case badEndpoint(String)
    case connection(String)
    case daemon(String)
    case wrongWorkspace(expected: String, actual: String)
    case historyUnavailable
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Slack is not configured. Add the dobbs endpoint and token in Electragne Settings."
        case .badEndpoint(let endpoint):
            "The dobbs endpoint ‘\(endpoint)’ is not a valid host:port."
        case .connection(let detail):
            "Could not reach the dobbs daemon: \(detail)"
        case .daemon(let message):
            "The dobbs daemon reported an error: \(message)"
        case .wrongWorkspace(let expected, let actual):
            "The dobbs daemon serves workspace ‘\(actual)’, but Settings expects ‘\(expected)’."
        case .historyUnavailable:
            "The dobbs daemon has no message archive available."
        case .timedOut:
            "The dobbs daemon did not respond in time."
        }
    }
}

/// One archived Slack message. Covers both the history and search-hit wire
/// shapes (a search hit adds `snippet`, which is ignored in favor of `text`).
nonisolated struct DobbsMessage: Decodable, Equatable, Sendable {
    var channelID: String? = nil
    var channelName: String? = nil
    var userID: String? = nil
    var userName: String? = nil
    var text: String? = nil
    var ts: String
    var threadTS: String? = nil
    var timeUnixNano: Int64? = nil

    enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case channelName = "channel_name"
        case userID = "user_id"
        case userName = "user_name"
        case text
        case ts
        case threadTS = "thread_ts"
        case timeUnixNano = "time_unix_nano"
    }

    var time: Date? {
        guard let nanos = timeUnixNano, nanos != 0 else { return nil }
        return Date(timeIntervalSince1970: Double(nanos) / 1_000_000_000)
    }
}

/// One workspace-directory entry from the daemon's users_list RPC.
nonisolated struct DobbsUser: Decodable, Equatable, Sendable {
    var id: String
    var name: String? = nil
    var realName: String? = nil
    var displayName: String? = nil
    var deleted: Bool? = nil
    var isBot: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case realName = "real_name"
        case displayName = "display_name"
        case deleted
        case isBot = "is_bot"
    }
}

nonisolated enum DobbsClient {
    static let protocolVersion = 2
    private static let callTimeout: Duration = .seconds(20)

    /// Full-text search of the daemon's archive (FTS5 syntax).
    static func search(_ settings: DobbsSettings, query: String, limit: Int) async throws -> [DobbsMessage] {
        struct Params: Encodable {
            let query: String
            let limit: Int
        }
        struct Result: Decodable {
            let results: [DobbsMessage]?
        }
        let result: Result = try await call(settings, method: "search", params: Params(query: query, limit: limit))
        return result.results ?? []
    }

    /// A channel's messages between two times (unix nanoseconds; 0 leaves that
    /// bound open), oldest-first. channel is a channel name or id.
    static func conversationRange(
        _ settings: DobbsSettings, channel: String, from: Int64, to: Int64
    ) async throws -> [DobbsMessage] {
        struct Params: Encodable {
            let channel: String
            let from: Int64
            let to: Int64
        }
        struct Result: Decodable {
            let messages: [DobbsMessage]?
        }
        let result: Result = try await call(
            settings, method: "conversation_range",
            params: Params(channel: channel, from: from, to: to)
        )
        return result.messages ?? []
    }

    /// A whole thread (root + replies) from the archive, oldest-first.
    static func conversation(
        _ settings: DobbsSettings, channelID: String, threadTS: String, limit: Int
    ) async throws -> [DobbsMessage] {
        struct Params: Encodable {
            let channelID: String
            let threadTS: String
            let limit: Int

            enum CodingKeys: String, CodingKey {
                case channelID = "channel_id"
                case threadTS = "thread_ts"
                case limit
            }
        }
        struct Result: Decodable {
            let messages: [DobbsMessage]?
        }
        let result: Result = try await call(
            settings, method: "conversation",
            params: Params(channelID: channelID, threadTS: threadTS, limit: limit)
        )
        return result.messages ?? []
    }

    /// The workspace directory.
    static func usersList(_ settings: DobbsSettings) async throws -> [DobbsUser] {
        struct Params: Encodable {}
        struct Result: Decodable {
            let users: [DobbsUser]?
        }
        let result: Result = try await call(
            settings, method: "users_list", params: Params(), needsHistory: false
        )
        return result.users ?? []
    }

    /// Posts text to a channel (into a thread when threadTS is set) through the
    /// daemon and returns the new message's ts. channel is a channel ID.
    static func postMessage(
        _ settings: DobbsSettings, channel: String, text: String, threadTS: String?
    ) async throws -> String {
        struct Params: Encodable {
            let channel: String
            let text: String
            let threadTS: String?

            enum CodingKeys: String, CodingKey {
                case channel
                case text
                case threadTS = "thread_ts"
            }
        }
        struct Result: Decodable {
            let ts: String?
        }
        let result: Result = try await call(
            settings, method: "post_message",
            params: Params(channel: channel, text: text, threadTS: threadTS),
            needsHistory: false
        )
        return result.ts ?? ""
    }

    /// A message's browser permalink. channel is a channel ID.
    static func getPermalink(_ settings: DobbsSettings, channel: String, ts: String) async throws -> String {
        struct Params: Encodable {
            let channel: String
            let ts: String
        }
        struct Result: Decodable {
            let url: String?
        }
        let result: Result = try await call(
            settings, method: "get_permalink", params: Params(channel: channel, ts: ts),
            needsHistory: false
        )
        return result.url ?? ""
    }

    // MARK: - One-shot RPC

    private struct ClientHello: Encodable {
        let `protocol`: Int
        let token: String
    }

    private struct Request<P: Encodable>: Encodable {
        let id: UInt64
        let method: String
        let params: P
    }

    /// The routing fields of a server frame; result payloads are decoded in a
    /// second pass so each caller picks its own result type.
    private struct FrameHead: Decodable {
        var id: UInt64?
        var error: String?
        var event: String?
    }

    private struct ResultBody<R: Decodable>: Decodable {
        let result: R
    }

    private struct Hello: Decodable {
        var teamName: String?
        var historyAvailable: Bool?

        enum CodingKeys: String, CodingKey {
            case teamName = "team_name"
            case historyAvailable = "history_available"
        }
    }

    private static func call<P: Encodable & Sendable, R: Decodable & Sendable>(
        _ settings: DobbsSettings, method: String, params: P, needsHistory: Bool = true
    ) async throws -> R {
        try await withTimeout(callTimeout) {
            let connection = try await DobbsConnection.connect(endpoint: settings.endpoint)
            defer { connection.cancel() }

            try await connection.sendLine(JSONEncoder().encode(
                ClientHello(protocol: protocolVersion, token: settings.token)
            ))
            try await readHello(connection, settings: settings, needsHistory: needsHistory)

            try await connection.sendLine(JSONEncoder().encode(
                Request(id: 1, method: method, params: params)
            ))
            while true {
                let line = try await connection.readLine()
                let head = try JSONDecoder().decode(FrameHead.self, from: line)
                if head.event != nil { continue } // unsolicited push; not ours
                guard head.id == 1 else { continue }
                if let error = head.error { throw DobbsError.daemon(error) }
                return try JSONDecoder().decode(ResultBody<R>.self, from: line).result
            }
        }
    }

    private static func readHello(
        _ connection: DobbsConnection, settings: DobbsSettings, needsHistory: Bool
    ) async throws {
        let line = try await connection.readLine()
        let head = try JSONDecoder().decode(FrameHead.self, from: line)
        if let error = head.error { throw DobbsError.daemon(error) }
        guard head.event == "hello" else {
            throw DobbsError.daemon("first frame was not hello")
        }
        struct Body: Decodable {
            let data: Hello
        }
        let hello = try JSONDecoder().decode(Body.self, from: line).data
        if let expected = settings.workspace, !expected.isEmpty {
            let actual = hello.teamName ?? ""
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                throw DobbsError.wrongWorkspace(expected: expected, actual: actual)
            }
        }
        // The live-API methods (post/users/permalink) work without an archive.
        if needsHistory {
            guard hello.historyAvailable == true else { throw DobbsError.historyUnavailable }
        }
    }

    private static func withTimeout<T: Sendable>(
        _ limit: Duration, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw DobbsError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

/// One TCP connection carrying newline-delimited JSON frames, read serially.
nonisolated private final class DobbsConnection: @unchecked Sendable {
    private let connection: NWConnection
    private var buffer = Data() // touched only by the single serial caller

    private init(connection: NWConnection) {
        self.connection = connection
    }

    static func connect(endpoint: String) async throws -> DobbsConnection {
        guard let colon = endpoint.lastIndex(of: ":"),
              let port = NWEndpoint.Port(String(endpoint[endpoint.index(after: colon)...])),
              case let host = String(endpoint[..<colon]), !host.isEmpty else {
            throw DobbsError.badEndpoint(endpoint)
        }
        let parameters = NWParameters.tcp
        if UserPreferences.dobbsUseProxy() {
            let context = NWParameters.PrivacyContext(description: "dobbs-socks5")
            context.proxyConfigurations = SOCKSProxy.proxyConfigurations()
            parameters.setPrivacyContext(context)
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        let wrapper = DobbsConnection(connection: connection)
        let resumed = ResumeOnce()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        resumed.run { continuation.resume() }
                    case .failed(let error), .waiting(let error):
                        // .waiting means unreachable right now (refused, no
                        // route); fail fast instead of letting the timeout hit.
                        connection.cancel()
                        resumed.run {
                            continuation.resume(throwing: DobbsError.connection(error.localizedDescription))
                        }
                    case .cancelled:
                        resumed.run {
                            continuation.resume(throwing: DobbsError.connection("connection cancelled"))
                        }
                    default:
                        break
                    }
                }
                connection.start(queue: .global())
            }
        } onCancel: {
            connection.cancel()
        }
        return wrapper
    }

    func cancel() {
        connection.cancel()
    }

    func sendLine(_ payload: Data) async throws {
        var framed = payload
        framed.append(0x0A)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: DobbsError.connection(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func readLine() async throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                return line
            }
            buffer.append(try await receiveChunk())
        }
    }

    private func receiveChunk() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: DobbsError.connection(error.localizedDescription))
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(throwing: DobbsError.connection("connection closed"))
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

/// Guards a continuation that competing NWConnection state callbacks might
/// otherwise resume twice.
nonisolated private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}
