import Foundation

/// Tool-name normalization across agent CLIs.
///
/// The same action has a different name in every agent: reading a file is `Read`, `ReadFile`,
/// or `read_file`; running a command is `Bash` or `run_in_terminal`. The notch shows one line
/// of text at collapsed size, so it has to be *the same* line of text regardless of which CLI
/// is talking — otherwise two sessions doing identical work look like they are doing different
/// work.
///
/// `Category` is the second half of the job: some tool calls are not "work" at all. Presenting
/// a plan or asking the user a question arrives as an ordinary `PreToolUse`, but it puts the
/// session into a waiting state rather than a running one. Matching on a category keeps that
/// decision out of the state machine's business.
nonisolated enum AgentTool {
    /// What a tool call *does*, independent of what the agent calls it.
    enum Category: String, Codable, Sendable, CaseIterable {
        case shell
        case read
        case write
        case edit
        case search
        case list
        case webFetch
        case webSearch
        /// The agent asked the user something and is blocked on the answer.
        case question
        /// The agent presented a plan and is blocked on approval or feedback.
        case plan
        /// Delegation to a subagent.
        case task
        case notebook
        case todo
        /// A tool provided by an MCP server.
        case mcp
        case other

        /// Whether a tool of this kind means the session is waiting on the human.
        var blocksOnUser: Bool {
            switch self {
            case .question, .plan: true
            default: false
            }
        }
    }

    private struct Entry {
        let displayName: String
        let category: Category
    }

    private static let mcpPrefix = "mcp__"

    /// Keyed by `matchKey`: lowercased with separators removed, so `read_file`, `ReadFile`, and
    /// `Read File` all collapse to `readfile`.
    private static let byMatchKey: [String: Entry] = {
        var table: [String: Entry] = [:]

        func register(_ names: [String], as displayName: String, _ category: Category) {
            for name in names {
                table[matchKey(name)] = Entry(displayName: displayName, category: category)
            }
        }

        register(
            ["Bash", "Shell", "run_in_terminal", "run_terminal_cmd", "execute_command", "terminal", "run_command", "run_shell_command", "exec_command", "shell_command", "execute_bash"],
            as: "Bash", .shell
        )
        register(
            ["Read", "ReadFile", "read_file", "view_file", "open_file"],
            as: "Read", .read
        )
        register(
            ["Write", "WriteFile", "write_file", "create_file", "new_file"],
            as: "Write", .write
        )
        register(
            ["Edit", "EditFile", "edit_file", "MultiEdit", "search_replace", "str_replace",
             "apply_patch", "ApplyPatch"],
            as: "Edit", .edit
        )
        register(
            ["Grep", "grep_code", "grep_search", "search_text", "ripgrep"],
            as: "Grep", .search
        )
        register(
            ["Glob", "search_file", "file_search", "find_files"],
            as: "Glob", .search
        )
        register(["list_dir", "ListDir", "ls"], as: "List", .list)
        register(
            ["WebFetch", "fetch_content", "fetch_url", "read_url"],
            as: "WebFetch", .webFetch
        )
        register(["WebSearch", "search_web", "web_search"], as: "WebSearch", .webSearch)
        register(
            ["AskUserQuestion", "ask_user_question", "ask_question", "request_user_input",
             "elicitation"],
            as: "AskUserQuestion", .question
        )
        register(
            ["ExitPlanMode", "exit_plan_mode", "present_plan", "submit_plan"],
            as: "ExitPlanMode", .plan
        )
        register(["Task", "Agent", "dispatch_agent", "spawn_agent"], as: "Task", .task)
        register(["NotebookEdit", "notebook_edit"], as: "NotebookEdit", .notebook)
        register(["TodoWrite", "todo_write", "update_todos"], as: "TodoWrite", .todo)

        return table
    }()

    /// The label to show for a tool, or `nil` when the agent named no tool.
    ///
    /// Unrecognised tools pass through with their original name rather than being hidden — an
    /// unfamiliar tool name is still more informative to the user than blank space.
    static func displayName(for rawName: String?) -> String? {
        guard let trimmed = normalizedInput(rawName) else { return nil }
        if let mcp = mcpComponents(trimmed) {
            return mcp.tool.isEmpty ? mcp.server : "\(mcp.server): \(mcp.tool)"
        }
        return byMatchKey[matchKey(trimmed)]?.displayName ?? trimmed
    }

    static func category(of rawName: String?) -> Category {
        guard let trimmed = normalizedInput(rawName) else { return .other }
        if mcpComponents(trimmed) != nil { return .mcp }
        return byMatchKey[matchKey(trimmed)]?.category ?? .other
    }

    private static func normalizedInput(_ rawName: String?) -> String? {
        guard let trimmed = rawName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// `mcp__github__create_issue` reads better as `github: create_issue`.
    private static func mcpComponents(_ name: String) -> (server: String, tool: String)? {
        guard name.lowercased().hasPrefix(mcpPrefix) else { return nil }
        let parts = name.dropFirst(mcpPrefix.count).components(separatedBy: "__")
        guard let server = parts.first, !server.isEmpty else { return nil }
        return (server, parts.dropFirst().joined(separator: "__"))
    }

    private static func matchKey(_ name: String) -> String {
        name.reduce(into: "") { result, character in
            guard character.isLetter || character.isNumber else { return }
            result.append(contentsOf: character.lowercased())
        }
    }
}

nonisolated extension AgentTool {
    /// The one line of a tool call's input that says what the call will actually *do*.
    ///
    /// Agents send `tool_input` as a whole JSON object, and serializing it was accurate and
    /// useless: the approval card's line of detail read
    /// `{"questions":[{"header":"Mascot path","multiSelect":false,"options":[{"descript…` —
    /// punctuation and schema where the command should be. The card is the one surface in the
    /// app that has to be answered from across a desk, so it gets the field that carries the
    /// decision (the command for a shell call, the path for a write, the question for a
    /// question) and nothing else. The full input is in the agent's own transcript.
    ///
    /// Nothing here ever throws away the input silently: an unrecognised shape falls through to
    /// a digest of its scalar fields, and then to the JSON it used to print. An ugly line is
    /// still better than a blank one on the card that blocks the agent.
    static func inputSummary(category: Category, input: JSONValue) -> String? {
        switch input {
        case .null:
            return nil
        case .string, .number, .bool:
            return input.compactSummary()
        case .array, .object:
            break
        }

        if let value = input.firstValue(forKeys: summaryKeys(for: category)),
           let text = value.compactSummary(limit: summaryLimit),
           !text.isEmpty {
            return category.namesAPath ? abbreviatedPath(text) : text
        }

        return scalarDigest(of: input) ?? input.compactSummary(limit: summaryLimit)
    }

    /// One line of a 640pt panel in an 11pt monospace is about 100 characters. Past roughly
    /// twice that, every extra character is one the user cannot read anyway.
    private static let summaryLimit = 220

    /// Keys in priority order — `firstValue(forKeys:)` honours the order at each level before
    /// descending, so `AskUserQuestion` resolves to the question rather than to the header of
    /// whichever option hashed first.
    private static func summaryKeys(for category: Category) -> [String] {
        switch category {
        case .shell:
            ["command", "cmd", "script", "description"]
        case .read, .write, .edit:
            ["file_path", "filepath", "path", "filename", "file", "target_file"]
        case .notebook:
            ["notebook_path", "file_path", "path"]
        case .search:
            ["pattern", "regex", "query", "glob", "path"]
        case .list:
            ["path", "directory", "dir", "target_directory"]
        case .webFetch:
            ["url", "prompt"]
        case .webSearch:
            ["query", "search_term", "q"]
        case .question:
            ["question", "header", "prompt"]
        case .plan:
            ["plan", "markdown", "description"]
        case .task:
            ["description", "prompt", "subagent_type"]
        case .todo:
            []
        case .mcp, .other:
            ["command", "query", "url", "prompt", "path", "file_path", "description", "name"]
        }
    }

    /// A digest for a shape no category claims: the scalar fields, in key order, and none of
    /// the nested structure. `{"limit":50,"owner":"anthropics","repo":"claude-code"}` becomes
    /// `limit: 50 · owner: anthropics · repo: claude-code`, which is the same information
    /// without asking the user to read JSON.
    private static func scalarDigest(of input: JSONValue) -> String? {
        guard case .object(let object) = input else { return nil }
        let parts = object.keys.sorted().compactMap { key -> String? in
            guard let value = object[key] else { return nil }
            switch value {
            case .array, .object, .null:
                return nil
            case .string, .number, .bool:
                guard let text = value.compactSummary(limit: 48), !text.isEmpty else {
                    return nil
                }
                return "\(key): \(text)"
            }
        }
        guard !parts.isEmpty else { return nil }
        return parts.prefix(3).joined(separator: " · ")
    }

    /// `/Users/you/code/The Notch/Core/Theme.swift` → `…/Core/Theme.swift`.
    ///
    /// The leading components are the same on every row the user will ever see; the file is the
    /// part that differs, and it is the part an absolute path pushes off the end of the line.
    private static func abbreviatedPath(_ path: String) -> String {
        guard path.contains("/") else { return path }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 2 else { return path }
        return "…/" + components.suffix(2).joined(separator: "/")
    }
}

nonisolated private extension AgentTool.Category {
    /// Whether this category's summary field holds a filesystem path, and so should be
    /// abbreviated rather than printed whole.
    var namesAPath: Bool {
        switch self {
        case .read, .write, .edit, .notebook, .list: true
        default: false
        }
    }
}
