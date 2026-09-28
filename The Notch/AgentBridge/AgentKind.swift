import Foundation

nonisolated enum AgentKind: Hashable, Sendable {
    case claudeCode
    case codex
    case opencode
    case antigravity
    case kiro
    case gemini
    case cursor
    case other(String)

    init(source: String) {
        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "claude", "claude-code", "claude_code", "claudecode":
            self = .claudeCode
        case "codex", "openai-codex", "openai_codex", "codex-app", "codex-cli":
            self = .codex
        case "opencode", "open-code", "opencode-cli", "opencode-app":
            self = .opencode
        case "antigravity", "antigravity-cli", "antigravity-ide", "agy":
            self = .antigravity
        case "kiro", "kiro-cli", "kiro-ide":
            self = .kiro
        case "gemini", "gemini-cli", "gemini_cli":
            self = .gemini
        case "cursor", "cursor-agent", "cursor_agent":
            self = .cursor
        default:
            self = .other(source)
        }
    }

    var displayName: String {
        switch self {
        case .claudeCode:
            "Claude Code"
        case .codex:
            "Codex"
        case .opencode: "OpenCode"
        case .antigravity: "Antigravity"
        case .kiro: "Kiro"
        case .gemini:
            "Gemini"
        case .cursor:
            "Cursor"
        case .other(let source):
            source.isEmpty ? "Other Agent" : source
        }
    }

    /// The sprite that stands in for this agent in the collapsed pill and in row gutters.
    var glyph: PixelGlyph {
        switch self {
        case .claudeCode:
            .claude
        case .codex:
            .codex
        case .gemini:
            .gemini
        case .cursor:
            .cursor
        case .opencode, .antigravity, .kiro, .other:
            .chip
        }
    }
}
