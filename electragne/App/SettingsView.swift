//
//  SettingsView.swift
//  electragne
//
//  The Settings window shell; each tab owns its own state and lives in
//  its own file (GeneralSettingsTab, IntegrationsSettingsTab,
//  MCPSettingsTab).
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            IntegrationsSettingsTab()
                .tabItem { Label("Integrations", systemImage: "link") }
            MCPSettingsTab()
                .tabItem { Label("MCP", systemImage: "wrench.and.screwdriver") }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // This view is hosted in a manually managed NSWindow. Keep its viewport
        // stable so account updates cannot trigger an AppKit layout recursion.
        .frame(width: 560, height: 520)
    }
}

/// Outcome of a Keychain save, driving the caption under each save button.
struct SaveStatus {
    var message: String?
    var failed = false
}

/// Writes a key field to Keychain, echoes back the stored value, and
/// returns the status line for its section.
func saveKeychainKey(
    _ key: Binding<String>,
    for provider: ChatAPIProvider,
    removalHint: String
) -> SaveStatus {
    do {
        try ChatAPIKeyStore.setKey(key.wrappedValue, for: provider)
        key.wrappedValue = ChatAPIKeyStore.key(for: provider) ?? ""
        return SaveStatus(message: "Saved in macOS Keychain. \(removalHint)")
    } catch {
        return SaveStatus(message: error.localizedDescription, failed: true)
    }
}

/// Fetches a model list into (models, error) state, with the shared
/// could-not-load message on failure.
func loadModels<Model>(
    into models: Binding<[Model]>,
    error errorText: Binding<String?>,
    fetch: @escaping () async throws -> [Model]
) {
    Task {
        do {
            models.wrappedValue = try await fetch()
            errorText.wrappedValue = nil
        } catch {
            errorText.wrappedValue = "Could not load the model list: \(error.localizedDescription)"
        }
    }
}
