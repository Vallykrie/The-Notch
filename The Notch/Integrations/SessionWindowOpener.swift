import AppKit
import Foundation

/// Brings a session's window forward from its row in the panel.
///
/// The precise route is `TerminalJumper`, which can select the exact iTerm session or Terminal
/// tab, or open the project folder in VS Code, Cursor or Zed. When that cannot place the
/// session — no host was worked out, or the host app has quit — it falls back to opening the
/// host app, and then to the agent's own app, so the button always does something sensible.
@MainActor
enum SessionWindowOpener {
    private static let jumper = TerminalJumper()

    static func canOpen(_ session: AgentSession) -> Bool {
        session.host != nil || agentApplicationURL(for: session.kind) != nil
    }

    static func open(_ session: AgentSession) {
        Task {
            if let host = session.host {
                let target = JumpTarget(
                    sessionID: session.id,
                    cwd: session.cwd,
                    agentKind: session.kind,
                    processID: host.agentProcessID,
                    termProgram: host.termProgram,
                    termSessionID: host.termSessionID,
                    iTermSessionID: host.iTermSessionID,
                    tty: host.tty,
                    hintedBundleIdentifier: host.bundleIdentifier
                )
                if case .failed = await jumper.jump(to: target) {
                    launch(NSWorkspace.shared.urlForApplication(withBundleIdentifier: host.bundleIdentifier))
                }
                return
            }
            launch(agentApplicationURL(for: session.kind))
        }
    }

    private static func launch(_ url: URL?) {
        guard let url else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    private static func agentApplicationURL(for kind: AgentKind) -> URL? {
        AgentCLI.allCases
            .first { AgentKind(source: $0.rawValue) == kind }
            .flatMap(AgentPresenceScanner.installedApplicationURL(for:))
    }
}
