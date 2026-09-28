import Foundation

/// The best-effort location information supplied by an agent hook.
///
/// Every terminal-specific value is optional because hooks differ between agents and versions.
/// Strategies must treat missing hints as a reason to reduce precision, not as an error.
nonisolated struct JumpTarget: Sendable {
    let sessionID: String
    let cwd: String
    let agentKind: AgentKind
    let processID: pid_t?
    let parentProcessID: pid_t?
    let termProgram: String?
    let termSessionID: String?
    let iTermSessionID: String?
    let tty: String?
    let wezTermPane: String?
    let hintedBundleIdentifier: String?

    init(
        sessionID: String,
        cwd: String,
        agentKind: AgentKind,
        processID: pid_t? = nil,
        parentProcessID: pid_t? = nil,
        termProgram: String? = nil,
        termSessionID: String? = nil,
        iTermSessionID: String? = nil,
        tty: String? = nil,
        wezTermPane: String? = nil,
        hintedBundleIdentifier: String? = nil
    ) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.agentKind = agentKind
        self.processID = processID
        self.parentProcessID = parentProcessID
        self.termProgram = termProgram
        self.termSessionID = termSessionID
        self.iTermSessionID = iTermSessionID
        self.tty = tty
        self.wezTermPane = wezTermPane
        self.hintedBundleIdentifier = hintedBundleIdentifier
    }

    init(session: AgentSession, payload: [String: JSONValue] = [:]) {
        let root = JSONValue.object(payload)
        self.init(
            sessionID: session.id,
            cwd: session.cwd,
            agentKind: session.kind,
            processID: Self.processID(root, keys: ["pid", "process_id", "processid", "client_pid"]),
            parentProcessID: Self.processID(
                root,
                keys: ["ppid", "parent_pid", "parent_process_id", "client_ppid"]
            ),
            termProgram: Self.string(root, keys: ["term_program", "termprogram"]),
            termSessionID: Self.string(root, keys: ["term_session_id", "termsessionid"]),
            iTermSessionID: Self.string(root, keys: ["iterm_session_id", "itermsessionid"]),
            tty: Self.string(root, keys: ["tty", "terminal_tty", "terminaltty"]),
            wezTermPane: Self.string(root, keys: ["wezterm_pane", "weztermpane"]),
            hintedBundleIdentifier: Self.string(
                root,
                keys: ["terminal_bundle_id", "bundle_identifier", "bundle_id"]
            )
        )
    }

    /// Keys are ordered, not a set: several agents send the same fact under different names, and
    /// the first key listed is the one we trust most. A `Set` left that choice to hash order.
    private static func string(_ root: JSONValue, keys: [String]) -> String? {
        guard let value = root.firstValue(forKeys: keys)?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func processID(_ root: JSONValue, keys: [String]) -> pid_t? {
        guard let value = root.firstValue(forKeys: keys) else { return nil }
        let candidate: Int64?
        switch value {
        case .number(let number) where number.isFinite && number.rounded() == number:
            candidate = Int64(exactly: number)
        case .string(let string):
            candidate = Int64(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            candidate = nil
        }
        guard let candidate, candidate > 0, candidate <= Int64(Int32.max) else { return nil }
        return pid_t(candidate)
    }
}
