import Foundation
import Testing
@testable import electragne

struct FileToolsTests {
    @Test func parsesDesktopToolRequests() throws {
        #expect(try DesktopToolRequest(toolCall: call("open_app", ["name": .string("Safari")])) == .openApp(name: "Safari"))
        #expect(try DesktopToolRequest(toolCall: call("open_url", ["url": .string("https://example.com/docs")])) == .openURL(URL(string: "https://example.com/docs")!))
        #expect(try DesktopToolRequest(toolCall: call("find_files", ["query": .string("quarterly report")])) == .findFiles(query: "quarterly report"))
        #expect(try DesktopToolRequest(toolCall: call("reveal_in_finder", ["fileID": .string("opaque-1")])) == .revealInFinder(fileID: "opaque-1"))
    }

    @Test func rejectsUnsafeURLsAndMissingArguments() {
        #expect(throws: DesktopToolError.invalidWebURL("file:///tmp/private.txt")) {
            try DesktopToolRequest(toolCall: call("open_url", ["url": .string("file:///tmp/private.txt")]))
        }
        #expect(throws: DesktopToolError.invalidWebURL("javascript:alert(1)")) {
            try DesktopToolRequest(toolCall: call("open_url", ["url": .string("javascript:alert(1)")]))
        }
        #expect(throws: DesktopToolError.missingArgument("query")) {
            try DesktopToolRequest(toolCall: call("find_files", ["query": .string("  ")]))
        }
    }

    @Test func onlyReadOnlySearchSkipsConfirmation() throws {
        let search = try DesktopToolRequest(toolCall: call("find_files", ["query": .string("notes")]))
        let app = try DesktopToolRequest(toolCall: call("open_app", ["name": .string("Notes")]))
        let web = try DesktopToolRequest(toolCall: call("open_url", ["url": .string("https://example.com")]))
        let reveal = try DesktopToolRequest(toolCall: call("reveal_in_finder", ["fileID": .string("1")]))

        #expect(search.confirmation == nil)
        #expect(app.confirmation?.actionLabel == "Open")
        #expect(web.confirmation?.primaryText == "https://example.com")
        #expect(reveal.confirmation?.actionLabel == "Show")
    }

    @Test func applicationLocatorUsesLaunchServicesAliasesAndSafeExactPaths() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        #expect(ApplicationLocator.bundleIdentifier(for: "Safari") == "com.apple.Safari")
        #expect(ApplicationLocator.bundleIdentifier(for: " Safari.app ") == "com.apple.Safari")
        #expect(ApplicationLocator.bundleIdentifier(for: "com.example.MyApp") == "com.example.MyApp")
        #expect(ApplicationLocator.candidateURLs(for: "Acme Editor", homeDirectory: home).map(\.path) == [
            "/Applications/Acme Editor.app",
            "/System/Applications/Acme Editor.app",
            "/System/Applications/Utilities/Acme Editor.app",
            "/Users/example/Applications/Acme Editor.app",
        ])
        #expect(ApplicationLocator.candidateURLs(for: "../Safari", homeDirectory: home).isEmpty)
    }

    @Test func fileSearchRanksNamesAndSkipsHiddenItems() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("electragne-file-search-\(UUID().uuidString)", isDirectory: true)
        let reports = root.appendingPathComponent("Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data().write(to: root.appendingPathComponent("quarterly report.pdf"))
        try Data().write(to: reports.appendingPathComponent("quarterly report notes.txt"))
        try Data().write(to: root.appendingPathComponent(".quarterly report secret.txt"))

        let matches = FileSearchEngine.search(query: "quarterly report", roots: [root])

        #expect(matches.map(\.relativePath) == [
            "quarterly report.pdf",
            "Reports/quarterly report notes.txt",
        ])
        #expect(matches.allSatisfy { $0.scopeName == root.lastPathComponent })
    }

    @Test func fileSearchMatchesFolderPathAndHonorsLimit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("electragne-file-search-\(UUID().uuidString)", isDirectory: true)
        let invoices = root.appendingPathComponent("Invoices 2026", isDirectory: true)
        try FileManager.default.createDirectory(at: invoices, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data().write(to: invoices.appendingPathComponent("Acme.pdf"))
        try Data().write(to: invoices.appendingPathComponent("Other.pdf"))

        let matches = FileSearchEngine.search(query: "invoices Acme", roots: [root], maxResults: 1)

        #expect(matches.count == 1)
        #expect(matches.first?.relativePath == "Invoices 2026/Acme.pdf")
    }

    private func call(_ name: String, _ arguments: [String: ChatToolValue]) -> ChatToolCall {
        ChatToolCall(id: "test-call", name: name, arguments: arguments)
    }
}
