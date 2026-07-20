//
//  DesktopToolRequest.swift
//  electragne
//
//  Parsing and validation of desktop tool calls (open app/URL, find files,
//  reveal in Finder).
//

import Foundation

nonisolated enum DesktopToolRequest: Equatable, Sendable {
    case openApp(name: String)
    case openURL(URL)
    case findFiles(query: String)
    case revealInFinder(fileID: String)

    init(toolCall: ChatToolCall) throws {
        func requiredString(_ key: String) throws -> String {
            let value = toolCall.arguments[key]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else { throw DesktopToolError.missingArgument(key) }
            return value
        }

        switch toolCall.name {
        case "open_app":
            self = .openApp(name: try requiredString("name"))
        case "open_url":
            let raw = try requiredString("url")
            guard let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  url.host != nil else {
                throw DesktopToolError.invalidWebURL(raw)
            }
            self = .openURL(url)
        case "find_files":
            self = .findFiles(query: try requiredString("query"))
        case "reveal_in_finder":
            self = .revealInFinder(fileID: try requiredString("fileID"))
        default:
            throw DesktopToolError.unsupportedTool(toolCall.name)
        }
    }

    var confirmation: ToolConfirmationDetails? {
        switch self {
        case .openApp(let name):
            return ToolConfirmationDetails(
                title: "Open this app?",
                primaryText: name,
                details: [],
                actionLabel: "Open"
            )
        case .openURL(let url):
            return ToolConfirmationDetails(
                title: "Open this website?",
                primaryText: url.absoluteString,
                details: [("Domain", url.host ?? "Unknown")],
                actionLabel: "Open"
            )
        case .revealInFinder:
            return ToolConfirmationDetails(
                title: "Show this item in Finder?",
                primaryText: "A file from the latest search",
                details: [],
                actionLabel: "Show"
            )
        case .findFiles:
            return nil
        }
    }

}

nonisolated enum DesktopToolError: LocalizedError, Equatable {
    case unsupportedTool(String)
    case missingArgument(String)
    case invalidWebURL(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedTool: "That tool request was invalid."
        case .missingArgument(let name): "The ‘\(name)’ argument is required."
        case .invalidWebURL: "Only complete HTTP and HTTPS web addresses can be opened."
        }
    }
}
