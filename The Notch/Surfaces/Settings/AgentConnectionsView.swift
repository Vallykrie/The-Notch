import AppKit
import SwiftUI

@MainActor
struct AgentConnectionsView: View {
    @ObservedObject var integrations: AgentIntegrationManager
    @ObservedObject var store: AgentSessionStore
    /// Where the back button returns to — Settings, or the empty agents panel.
    var backTitle = "Settings"
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("‹ \(backTitle)", action: onBack)
                Spacer()
                Button("Refresh") { Task { await integrations.refresh() } }
                Button("Copy custom bridge") {
                    let binary = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".the-notch/bin/notch-hook").path
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("printf '{}' | " + HookInstaller.shellQuote(binary) + " --source your-agent --event UserPromptSubmit --session SESSION_ID --cwd /path/to/project", forType: .string)
                }
                .help("Any app or CLI can send lifecycle events with its own provider name and stable session ID.")
            }
            .buttonStyle(.plain)
            .font(Theme.Text.caption)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                ForEach(integrations.statuses) { status in
                    HStack {
                        Text(status.provider.displayName)
                        Spacer(minLength: 4)
                        Text(label(for: status))
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .lineLimit(1)
                    }
                    .font(Theme.Text.micro)
                    .help(status.error ?? hint(for: status.provider))
                }
            }
            Text("App + CLI • Hooks may require a new session. Codex activity also uses local session files.")
                .font(Theme.Text.micro)
                .foregroundStyle(Theme.Colors.textTertiary)
                .lineLimit(2)
        }
    }

    private func label(for status: AgentIntegrationStatus) -> String {
        if store.sessionsByID.values.contains(where: { $0.kind == AgentKind(source: status.provider.rawValue) }) { return "Receiving activity" }
        if status.error != nil { return "Setup needs attention" }
        if !status.installed { return "Not detected" }
        return status.configured ? "Waiting for session" : "Not connected"
    }

    private func hint(for provider: AgentCLI) -> String {
        switch provider {
        case .codex: "Activity is read locally for desktop and CLI. For approval controls, review The Notch hooks in Codex /hooks; changed hooks need renewed trust."
        case .kiro: "Global lifecycle hooks support Kiro IDE 1.x and CLI 3.x. Older versions may need upgrading."
        default: "Hooks are installed without replacing other integrations. Start a new agent session to load them."
        }
    }
}
