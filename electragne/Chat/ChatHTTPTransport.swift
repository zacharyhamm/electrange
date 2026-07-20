import Foundation
import Network
import Synchronization

/// Builds URLSessions (and Network.framework proxy configs) that route through
/// the Tailscale sidecar's SOCKS5 proxy. The proxy receives hostnames, so
/// MagicDNS names resolve on the sidecar.
nonisolated enum SOCKSProxy {
    /// Split "host:port" into its parts, or nil when malformed.
    static func parse(_ endpoint: String) -> (host: String, port: UInt16)? {
        guard let colon = endpoint.lastIndex(of: ":"),
              let port = UInt16(endpoint[endpoint.index(after: colon)...]),
              case let host = String(endpoint[..<colon]), !host.isEmpty
        else { return nil }
        return (host, port)
    }

    /// Proxy configurations for the endpoint in Settings, or empty when malformed.
    static func proxyConfigurations() -> [ProxyConfiguration] {
        guard let (host, port) = parse(UserPreferences.socksProxyEndpoint()),
              let nwPort = NWEndpoint.Port(rawValue: port)
        else { return [] }
        return [ProxyConfiguration(socksv5Proxy: .hostPort(host: .init(host), port: nwPort))]
    }

    private static let cache = Mutex<(endpoint: String, session: URLSession)?>(nil)

    /// URLSession.shared, or a cached session routed through the SOCKS5 proxy.
    static func urlSession(proxied: Bool) -> URLSession {
        guard proxied else { return .shared }
        let endpoint = UserPreferences.socksProxyEndpoint()
        return cache.withLock { cached in
            if let cached, cached.endpoint == endpoint { return cached.session }
            let configuration = URLSessionConfiguration.default
            configuration.proxyConfigurations = proxyConfigurations()
            let session = URLSession(configuration: configuration)
            cached = (endpoint, session)
            return session
        }
    }
}

nonisolated extension AsyncThrowingStream where Element: Sendable, Failure == Error {
    /// A stream driven by a task that is cancelled when the consumer stops
    /// listening. The task's uncaught error (or normal return) finishes the
    /// stream.
    static func fromTask(
        _ body: @escaping @Sendable (Continuation) async throws -> Void
    ) -> AsyncThrowingStream {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await body(continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

nonisolated protocol ChatHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func lines(for request: URLRequest) async throws
        -> (AsyncThrowingStream<String, Error>, URLResponse)
}

nonisolated struct URLSessionTransport: ChatHTTPTransport {
    let session: URLSession

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    func lines(for request: URLRequest) async throws
        -> (AsyncThrowingStream<String, Error>, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        let stream = AsyncThrowingStream<String, Error>.fromTask { continuation in
            for try await line in bytes.lines { continuation.yield(line) }
        }
        return (stream, response)
    }
}
