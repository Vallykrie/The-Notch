import Foundation

nonisolated extension HookInstaller {
    func mutateProvider(root original: [String: Any], agent: AgentCLI, installing: Bool, at url: URL) throws -> (root: [String: Any], changed: Bool) {
        var root = original
        switch agent {
        case .cursor:
            if let version = root["version"] as? Int, version != 1 {
                throw HookInstallerError.invalidHookStructure(url, "unsupported Cursor hook version")
            }
            if root["hooks"] != nil && !(root["hooks"] is [String: Any]) {
                throw HookInstallerError.invalidHookStructure(url, "hooks must be an object")
            }
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            for event in agent.events {
                if hooks[event] != nil && !(hooks[event] is [[String: Any]]) {
                    throw HookInstallerError.invalidHookStructure(url, "invalid \(event) hooks")
                }
                var entries = (hooks[event] as? [[String: Any]] ?? []).filter { !owns($0, agent: agent) }
                if installing { entries.append(["command": hookCommand(agent: agent, event: event)]) }
                hooks[event] = entries.isEmpty ? nil : entries
            }
            root["version"] = 1
            root["hooks"] = hooks
        case .antigravity:
            // Antigravity groups events by hook name, unlike Claude/Gemini's outer hooks key.
            if installing {
                var hooks: [String: Any] = [:]
                for event in agent.events {
                    let handler: [String: Any] = ["type": "command", "command": hookCommand(agent: agent, event: event), "timeout": 5]
                    hooks[event] = event == "PreToolUse" || event == "PostToolUse"
                        ? [["matcher": ".*", "hooks": [handler]]]
                        : [handler]
                }
                root["the-notch"] = hooks
            } else { root.removeValue(forKey: "the-notch") }
        case .kiro:
            if root["hooks"] != nil && !(root["hooks"] is [[String: Any]]) {
                throw HookInstallerError.invalidHookStructure(url, "hooks must be an array")
            }
            var hooks = (root["hooks"] as? [[String: Any]] ?? []).filter {
                !owns($0["action"] as? [String: Any] ?? [:], agent: agent)
            }
            if installing {
                hooks += agent.events.map { event in
                    ["name": "The Notch: \(event)", "trigger": event, "timeout": 5,
                     "action": ["type": "command", "command": hookCommand(agent: agent, event: event)]] as [String: Any]
                }
            }
            root["version"] = "v1"
            root["hooks"] = hooks
        default: break
        }
        return (root, !NSDictionary(dictionary: original).isEqual(to: root))
    }

    private func owns(_ entry: [String: Any], agent: AgentCLI) -> Bool {
        guard let command = entry["command"] as? String else { return false }
        return command.contains("notch-hook") && command.contains("--source \(agent.rawValue)")
    }

    func updateOpenCodePlugin(install: Bool) throws {
        let url = configurationURL(for: .opencode)
        let fm = FileManager.default
        let existing = try? Data(contentsOf: url)
        if !install {
            if let existing, String(decoding: existing, as: UTF8.self).hasPrefix("// The Notch integration") {
                try fm.removeItem(at: url)
            }
            return
        }
        let data = Data(Self.openCodePlugin.utf8)
        guard existing != data else { return }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if existing != nil {
            try fm.copyItem(at: url, to: URL(fileURLWithPath: url.path + ".backup." + UUID().uuidString))
        }
        try data.write(to: url, options: .atomic)
    }

    // Uses only Node/Bun built-ins. No shell interpolation, downloads, or stdout output.
    static let openCodePlugin = #"""
    // The Notch integration — OpenCode desktop and CLI.
    import { spawn } from "node:child_process";
    import { homedir } from "node:os";
    import { join } from "node:path";

    export const TheNotch = async ({ directory }) => {
      const emit = (event, session, extra = {}) => {
        if (!session) return;
        try {
          const child = spawn(join(homedir(), ".the-notch/bin/notch-hook"),
            ["--source", "opencode", "--event", event], { stdio: ["pipe", "ignore", "ignore"] });
          const timer = setTimeout(() => child.kill(), 1500);
          timer.unref();
          child.on("error", () => clearTimeout(timer));
          child.on("exit", () => clearTimeout(timer));
          child.stdin.on("error", () => {});
          child.stdin.end(JSON.stringify({ session_id: session, cwd: directory, ...extra }));
        } catch {}
      };
      return {
        event: async ({ event }) => {
          const p = event.properties ?? {};
          const session = p.sessionID ?? p.info?.sessionID ?? p.info?.id;
          switch (event.type) {
            case "session.created": emit("SessionStart", session); break;
            case "session.deleted": emit("SessionEnd", session); break;
            case "session.idle": emit("Stop", session); break;
            case "session.status":
              emit(p.status?.type === "idle" ? "Stop" : "AgentThought", session); break;
            case "session.error": emit("Stop", session); break;
            case "session.compacted": emit("PostCompact", session); break;
            case "permission.asked": emit("AttentionRequired", session); break;
            case "permission.replied": emit("PermissionDenied", session); break;
          }
        },
        "chat.message": async (input) => emit("UserPromptSubmit", input.sessionID),
        "tool.execute.before": async (input, output) =>
          emit("PreToolUse", input.sessionID, { tool_name: input.tool, tool_input: output.args }),
        "tool.execute.after": async (input) =>
          emit("PostToolUse", input.sessionID, { tool_name: input.tool }),
      };
    };
    """#
}
