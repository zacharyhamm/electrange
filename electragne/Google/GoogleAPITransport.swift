//
//  GoogleAPITransport.swift
//  electragne
//
//  Authenticated HTTP transport shared by the Gmail and Calendar tools.
//

import Foundation

nonisolated enum GoogleAPIError: LocalizedError, Equatable {
    case invalidResponse
    case api(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Google returned an unreadable response."
        case .api(let status, let message): "Google returned HTTP \(status): \(message)"
        }
    }
}

@MainActor
protocol GoogleAPITransporting {
    func data(
        accountID: String,
        method: String,
        path: String,
        query: [URLQueryItem],
        body: Data?
    ) async throws -> Data
}

@MainActor
final class GoogleAPITransport: GoogleAPITransporting {
    private let tokens: any GoogleTokenProviding
    private let session: URLSession
    private let baseURL: URL

    init(
        tokens: (any GoogleTokenProviding)? = nil,
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://gmail.googleapis.com")!
    ) {
        self.tokens = tokens ?? GoogleOAuthService.shared
        self.session = session
        self.baseURL = baseURL
    }

    func data(
        accountID: String,
        method: String = "GET",
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> Data {
        // The path is used verbatim: literal segments plus IDs already encoded
        // via pathSegment(_:). appendingPathComponent would re-encode the "%".
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw GoogleAPIError.invalidResponse
        }
        components.percentEncodedPath = "/" + path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw GoogleAPIError.invalidResponse }
        let token = try await tokens.freshAccessToken(for: accountID)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GoogleAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = Self.googleErrorMessage(data) ?? "Request failed"
            throw GoogleAPIError.api(http.statusCode, message)
        }
        return data
    }

    /// Percent-encodes a model-supplied ID as a single path segment: "/" is
    /// encoded so the value cannot introduce extra segments, and the whole
    /// segments "." / ".." are encoded so they cannot act as dot-segments.
    nonisolated static func pathSegment(_ value: String) -> String {
        guard value != ".", value != ".." else {
            return value.replacingOccurrences(of: ".", with: "%2E")
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    nonisolated private static func googleErrorMessage(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }
}
