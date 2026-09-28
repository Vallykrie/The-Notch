import Foundation

/// Provider-specific installation is separate from the open wire protocol: any agent can
/// emit normalized events through notch-hook without being added to this registry.
nonisolated enum AgentCLI: String, CaseIterable, Sendable {
    case claude, codex, opencode, antigravity, cursor, gemini, kiro

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .antigravity: "Antigravity"
        case .cursor: "Cursor"
        case .gemini: "Gemini CLI"
        case .kiro: "Kiro"
        }
    }

    var executables: [String] {
        switch self {
        case .cursor: ["cursor-agent", "cursor"]
        case .kiro: ["kiro-cli", "kiro"]
        case .antigravity: ["antigravity", "agy"]
        default: [rawValue]
        }
    }

    var appNames: [String] {
        switch self {
        case .claude: ["Claude.app"]
        case .codex: ["Codex.app", "Codex Echo.app", "ChatGPT.app"]
        case .opencode: ["OpenCode.app", "opencode.app"]
        case .antigravity: ["Antigravity.app", "Antigravity IDE.app"]
        case .cursor: ["Cursor.app"]
        case .kiro: ["Kiro.app"]
        case .gemini: []
        }
    }

    var detectionDirectories: [String] {
        switch self {
        case .claude: [".claude"]
        case .codex: [".codex"]
        case .opencode: [".config/opencode", ".opencode"]
        case .antigravity: [".gemini/antigravity", ".gemini/antigravity-ide", ".gemini/antigravity-cli", ".antigravity"]
        case .cursor: [".cursor"]
        case .gemini: [".gemini/settings.json", ".gemini/tmp"]
        case .kiro: [".kiro"]
        }
    }

    var configurationRelativePath: String {
        switch self {
        case .claude: ".claude/settings.json"
        case .codex: ".codex/hooks.json"
        case .opencode: ".config/opencode/plugins/the-notch.js"
        case .antigravity: ".gemini/config/hooks.json"
        case .cursor: ".cursor/hooks.json"
        case .gemini: ".gemini/settings.json"
        case .kiro: ".kiro/hooks/the-notch.json"
        }
    }

    func configurationURL(home: URL, environment: [String: String]) -> URL {
        let override: String?
        let suffix: String
        switch self {
        case .codex: override = environment["CODEX_HOME"]; suffix = "hooks.json"
        case .claude: override = environment["CLAUDE_CONFIG_DIR"]; suffix = "settings.json"
        case .opencode:
            override = environment["OPENCODE_CONFIG_DIR"] ?? environment["XDG_CONFIG_HOME"].map { $0 + "/opencode" }
            suffix = "plugins/the-notch.js"
        default: override = nil; suffix = ""
        }
        if let override, override.hasPrefix("/") {
            return URL(fileURLWithPath: override).appendingPathComponent(suffix)
        }
        return home.appendingPathComponent(configurationRelativePath)
    }

    var events: [String] {
        switch self {
        case .claude: ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "Notification", "Stop", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact", "PermissionRequest"]
        case .codex: ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact", "PermissionRequest", "Interrupt"]
        case .gemini: ["SessionStart", "SessionEnd", "BeforeAgent", "AfterAgent", "BeforeTool", "AfterTool", "PreCompress", "Notification"]
        case .cursor: ["sessionStart", "sessionEnd", "beforeSubmitPrompt", "preToolUse", "postToolUse", "postToolUseFailure", "subagentStart", "subagentStop", "preCompact", "stop", "afterAgentThought"]
        case .antigravity: ["PreToolUse", "PostToolUse", "PreInvocation", "PostInvocation", "Stop"]
        case .kiro: ["SessionStart", "AgentSpawn", "PromptSubmit", "PreToolUse", "PostToolUse", "Stop"]
        case .opencode: [] // Native plugin subscribes to the event stream.
        }
    }
}
