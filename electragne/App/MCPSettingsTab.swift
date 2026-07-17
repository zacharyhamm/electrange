//
//  MCPSettingsTab.swift
//  electragne
//
//  Settings tab for remote MCP servers: add/remove servers and choose a
//  per-tool permission policy (Allowed / Ask / Forbidden).
//

import SwiftUI

struct MCPSettingsTab: View {
    @State private var manager = MCPServerManager.shared
    @State private var newName = ""
    @State private var newURL = ""
    @State private var newToken = ""
    @State private var addError: String?
    // Picker needs a binding; policies live in UserDefaults via the catalog.
    // Bumping this counter re-reads them after a change.
    @State private var policyRevision = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("MCP servers")
                        .font(.headline)
                    Text("Connect remote MCP servers over Streamable HTTP. Their tools become available in chat; tokens are stored in macOS Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Name")
                        .font(.subheadline.weight(.medium))
                    TextField("e.g. Context7", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)

                    Text("URL")
                        .font(.subheadline.weight(.medium))
                        .padding(.top, 3)
                    TextField("https://example.com/mcp", text: $newURL)
                        .textFieldStyle(.roundedBorder)

                    Text("Bearer token (optional)")
                        .font(.subheadline.weight(.medium))
                        .padding(.top, 3)
                    SecureField("Paste the server's token", text: $newToken)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Spacer()
                        Button("Add Server", action: addServer)
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty
                                || URL(string: newURL.trimmingCharacters(in: .whitespaces))?.host == nil)
                    }
                    if let addError {
                        Text(addError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                ForEach(manager.servers) { server in
                    Divider()
                    serverSection(server)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
    }

    @ViewBuilder
    private func serverSection(_ server: MCPServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(server.name)
                    .font(.headline)
                statusBadge(for: server.id)
                Spacer()
                Button("Refresh") {
                    Task { await manager.refresh(server.id) }
                }
                Button("Remove", role: .destructive) {
                    manager.remove(server.id)
                }
            }
            Text(server.url.absoluteString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if case .failed(let message) = manager.status[server.id] {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(manager.tools[server.id] ?? [], id: \.namespacedName) { tool in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tool.toolName)
                            .font(.callout)
                        Text(tool.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer()
                    Picker("Policy for \(tool.toolName)", selection: policyBinding(for: tool)) {
                        ForEach(MCPToolPolicy.allCases, id: \.self) { policy in
                            Text(policy.label).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
            }
        }
    }

    @ViewBuilder
    private func statusBadge(for id: UUID) -> some View {
        switch manager.status[id] {
        case .connecting:
            ProgressView()
                .controlSize(.small)
        case .connected(let toolCount):
            Text("\(toolCount) tools")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        case nil:
            EmptyView()
        }
    }

    private func policyBinding(for tool: MCPToolDescriptor) -> Binding<MCPToolPolicy> {
        Binding(
            get: {
                _ = policyRevision
                return MCPToolCatalog.policy(for: tool.namespacedName)
            },
            set: { policy in
                MCPToolCatalog.setPolicy(policy, for: tool.namespacedName)
                policyRevision += 1
            }
        )
    }

    private func addServer() {
        guard let url = URL(string: newURL.trimmingCharacters(in: .whitespaces)) else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        // Compare namespace prefixes, not raw names: ‘My Server’ and
        // ‘my-server’ would otherwise collide into the same tool namespace.
        let prefix = MCPToolCatalog.namespacePrefix(server: name)
        guard !manager.servers.contains(where: {
            MCPToolCatalog.namespacePrefix(server: $0.name) == prefix
        }) else {
            addError = "‘\(name)’ conflicts with an existing server’s name."
            return
        }
        addError = nil
        let token = newToken
        newName = ""
        newURL = ""
        newToken = ""
        Task { await manager.add(name: name, url: url, token: token) }
    }
}
