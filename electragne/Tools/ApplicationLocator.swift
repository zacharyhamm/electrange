//
//  ApplicationLocator.swift
//  electragne
//
//  Maps human app names to bundle identifiers and candidate install
//  locations for the open_app tool.
//

import Foundation

nonisolated enum ApplicationLocator {
    private static let bundleIdentifiers: [String: String] = [
        "app store": "com.apple.AppStore",
        "calculator": "com.apple.calculator",
        "calendar": "com.apple.iCal",
        "contacts": "com.apple.AddressBook",
        "facetime": "com.apple.FaceTime",
        "finder": "com.apple.finder",
        "firefox": "org.mozilla.firefox",
        "google chrome": "com.google.Chrome",
        "mail": "com.apple.mail",
        "maps": "com.apple.Maps",
        "messages": "com.apple.MobileSMS",
        "music": "com.apple.Music",
        "notes": "com.apple.Notes",
        "photos": "com.apple.Photos",
        "preview": "com.apple.Preview",
        "reminders": "com.apple.reminders",
        "safari": "com.apple.Safari",
        "system preferences": "com.apple.systempreferences",
        "system settings": "com.apple.systempreferences",
        "terminal": "com.apple.Terminal",
        "tv": "com.apple.TV",
        "visual studio code": "com.microsoft.VSCode",
        "vs code": "com.microsoft.VSCode",
        "xcode": "com.apple.dt.Xcode",
    ]

    static func bundleIdentifier(for name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(".") && !trimmed.lowercased().hasSuffix(".app") {
            return trimmed
        }
        return bundleIdentifiers[normalizedName(trimmed)?.lowercased() ?? ""]
    }

    static func candidateURLs(for name: String, homeDirectory: URL) -> [URL] {
        guard let appName = normalizedName(name) else { return [] }
        let directories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true),
        ]
        return directories.map {
            $0.appendingPathComponent(appName, isDirectory: true).appendingPathExtension("app")
        }
    }

    private static func normalizedName(_ name: String) -> String? {
        var result = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.lowercased().hasSuffix(".app") { result.removeLast(4) }
        guard !result.isEmpty,
              result != ".",
              result != "..",
              !result.contains("/"),
              !result.contains(":"),
              !result.contains("\\") else { return nil }
        return result
    }
}
