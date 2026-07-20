import Foundation

/// Client for a self-hosted SearXNG instance's JSON search API. Backs the
/// web_search/image_search tools and Gemini's grounding-thumbnail lookup.
nonisolated struct SearXNGSearch {
    static let maxResults = 4
    static let maxResultCharacters = 1500
    static let maxThumbnails = 3
    static let maxGalleryImages = 6
    let transport: any ChatHTTPTransport

    enum Category: Equatable {
        case general
        case images
    }

    struct Output: Equatable {
        let text: String
        let images: [ChatImage]
    }

    init(transport: any ChatHTTPTransport = LoggingTransport(proxied: UserPreferences.searxngUseProxy())) {
        self.transport = transport
    }

    private struct SearchResponse: Decodable {
        struct Result: Decodable {
            let title: String?
            let url: String?
            let content: String?
            let thumbnail: String?
            let thumbnailSrc: String?
            let imageSrc: String?

            enum CodingKeys: String, CodingKey {
                case title, url, content, thumbnail
                case thumbnailSrc = "thumbnail_src"
                case imageSrc = "img_src"
            }
        }

        let results: [Result]
    }

    /// GET {endpoint}/search?q={query}&format=json for the configured endpoint.
    nonisolated static func searchURL(
        endpoint: String,
        query: String,
        category: Category = .general
    ) -> URL? {
        guard var components = URLComponents(string: endpoint) else { return nil }
        components.path = components.path.hasSuffix("/search")
            ? components.path : components.path + "/search"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
        ]
        if category == .images {
            components.queryItems?.append(URLQueryItem(name: "categories", value: "images"))
        }
        return components.url.flatMap { $0.scheme == nil ? nil : $0 }
    }

    func results(
        query: String,
        category: Category = .general,
        imageLimit: Int? = nil
    ) async throws -> Output {
        guard let endpoint = UserPreferences.searxngEndpoint(),
              let url = Self.searchURL(endpoint: endpoint, query: query, category: category) else {
            throw ChatProviderError.invalidEndpoint
        }

        let (data, response) = try await transport.data(for: URLRequest(url: url))
        try ChatProviderError.checkOK(response)
        return Self.formatOutput(from: data, category: category, imageLimit: imageLimit)
    }

    nonisolated static func formatResults(from data: Data) -> String {
        formatOutput(from: data).text
    }

    nonisolated static func formatOutput(
        from data: Data,
        category: Category = .general,
        imageLimit: Int? = nil
    ) -> Output {
        guard let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data),
              !decoded.results.isEmpty else {
            return Output(text: "No results found.", images: [])
        }
        let resultLimit = category == .images ? maxGalleryImages : maxResults
        let results = decoded.results.prefix(resultLimit)
        let text = results.enumerated().map { index, result in
            let content = String((result.content ?? "").prefix(maxResultCharacters))
            return """
                Result \(index + 1): \(result.title ?? "Untitled")
                URL: \(result.url ?? "unknown")
                \(content)
                """
        }.joined(separator: "\n\n")
        let limit = imageLimit ?? (category == .images ? maxGalleryImages : maxThumbnails)
        var seen = Set<String>()
        let images = results.compactMap { result in
            ChatImage(
                url: result.thumbnailSrc ?? result.thumbnail ?? result.imageSrc,
                sourceURL: result.url,
                title: result.title
            )
        }.filter { seen.insert($0.url).inserted }.prefix(limit)
        return Output(text: text, images: Array(images))
    }
}
