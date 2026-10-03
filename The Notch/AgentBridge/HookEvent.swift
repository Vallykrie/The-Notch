import Foundation

nonisolated enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    /// Depth-first lookup that honours the caller's key priority.
    ///
    /// Keys are tried in order at each level before descending, so a payload carrying both
    /// `cwd` and `workspace_current_dir` resolves the same way every time. Dictionary iteration
    /// order is not stable in Swift, so scanning "any key in a set" would have made the answer
    /// depend on hashing.
    func firstValue(forKeys keys: [String]) -> JSONValue? {
        switch self {
        case .object(let object):
            let lowercased = Dictionary(
                object.map { ($0.key.lowercased(), $0.value) },
                uniquingKeysWith: { first, _ in first }
            )
            for key in keys {
                if let value = lowercased[key], value != .null {
                    return value
                }
            }
            for key in object.keys.sorted() {
                if let match = object[key]?.firstValue(forKeys: keys) {
                    return match
                }
            }
        case .array(let values):
            for value in values {
                if let match = value.firstValue(forKeys: keys) {
                    return match
                }
            }
        default:
            break
        }
        return nil
    }

    func compactSummary(limit: Int = 300) -> String? {
        let result: String?
        switch self {
        case .string(let value):
            result = value
        case .number(let value):
            if value.rounded() == value,
               value >= Double(Int64.min),
               value <= Double(Int64.max) {
                result = String(Int64(value))
            } else {
                result = String(value)
            }
        case .bool(let value):
            result = String(value)
        case .null:
            result = nil
        case .array, .object:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            result = (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
        }
        guard let result else { return nil }
        let flattened = result
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(max(0, limit - 1))) + "…"
    }
}

/// A hook event, normalized across agent CLIs.
///
/// Claude Code and Codex both spell their events in PascalCase and their sets overlap without
/// matching: Claude has `Notification` and `PostToolUseFailure`, Codex has neither; Codex has
/// `PostCompact`, older Claude builds do not. Some agents (and the CLI-agnostic hook shims
/// people wrap around them) emit camelCase, verb-shaped names for the same moments —
/// `beforeToolUse` for `PreToolUse`, `afterAgentResponse` for `Stop`.
///
/// Every spelling we know of folds onto one case here, so the rest of the app reasons about
/// *moments* rather than vocabularies. Matching ignores case and separators, so `PreToolUse`,
/// `pre_tool_use`, and `preToolUse` are the same event.
///
/// Anything unrecognised becomes `.unknown` and is inert: it is recorded in the session's event
/// log and changes no state. That is the whole unknown-event contract — new agent versions can
/// invent events without us mis-reporting a session.
nonisolated enum EventName: Hashable, Sendable {
    case sessionStart
    case sessionEnd
    case userPromptSubmit
    case preToolUse
    case postToolUse
    case postToolUseFailure
    case notification
    case stop
    case subagentStart
    case subagentStop
    case preCompact
    case postCompact
    case permissionRequest
    case permissionDenied
    case elicitation
    case exitPlanMode
    case agentThought
    case unknown(String)

    /// Every accepted spelling, keyed by `matchKey` (lowercased, separators removed).
    private static let byMatchKey: [String: EventName] = [
        "sessionstart": .sessionStart,
        "agentspawn": .sessionStart,
        "promptsubmit": .userPromptSubmit,
        "beforeagent": .userPromptSubmit,
        "beforetool": .preToolUse,
        "afteragent": .stop,
        "interrupt": .stop,
        "precompress": .preCompact,
        "preinvocation": .agentThought,
        "postinvocation": .postToolUse,
        "attentionrequired": .elicitation,
        "agentthought": .agentThought,
        "sessionend": .sessionEnd,

        "userpromptsubmit": .userPromptSubmit,
        "userpromptexpansion": .userPromptSubmit,
        "beforesubmitprompt": .userPromptSubmit,

        "pretooluse": .preToolUse,
        "beforetooluse": .preToolUse,
        "beforeshellexecution": .preToolUse,
        "beforemcpexecution": .preToolUse,
        "beforereadfile": .preToolUse,

        "posttooluse": .postToolUse,
        "aftertool": .postToolUse,
        "aftertooluse": .postToolUse,
        "posttoolbatch": .postToolUse,
        "aftershellexecution": .postToolUse,
        "aftermcpexecution": .postToolUse,
        "afterfileedit": .postToolUse,

        "posttoolusefailure": .postToolUseFailure,

        "notification": .notification,

        "stop": .stop,
        "stopfailure": .stop,
        "afteragentresponse": .stop,

        "subagentstart": .subagentStart,
        "subagentstop": .subagentStop,

        "precompact": .preCompact,
        "postcompact": .postCompact,

        "permissionrequest": .permissionRequest,
        "permissiondenied": .permissionDenied,

        "elicitation": .elicitation,
        "exitplanmode": .exitPlanMode,

        "afteragentthought": .agentThought,
    ]

    init(rawValue: String) {
        self = Self.byMatchKey[Self.matchKey(rawValue)] ?? .unknown(rawValue)
    }

    /// The canonical spelling. Aliases normalize onto the name Claude Code and Codex agree on;
    /// unknown events keep whatever the agent sent so the log stays truthful.
    var rawValue: String {
        switch self {
        case .sessionStart: "SessionStart"
        case .sessionEnd: "SessionEnd"
        case .userPromptSubmit: "UserPromptSubmit"
        case .preToolUse: "PreToolUse"
        case .postToolUse: "PostToolUse"
        case .postToolUseFailure: "PostToolUseFailure"
        case .notification: "Notification"
        case .stop: "Stop"
        case .subagentStart: "SubagentStart"
        case .subagentStop: "SubagentStop"
        case .preCompact: "PreCompact"
        case .postCompact: "PostCompact"
        case .permissionRequest: "PermissionRequest"
        case .permissionDenied: "PermissionDenied"
        case .elicitation: "Elicitation"
        case .exitPlanMode: "ExitPlanMode"
        case .agentThought: "AgentThought"
        case .unknown(let value): value
        }
    }

    /// True for events we recognise. Used by the server to decide whether an event is worth
    /// waking the UI for; unknown events are still logged, never rejected.
    var isRecognised: Bool {
        if case .unknown = self { return false }
        return true
    }

    private static func matchKey(_ rawValue: String) -> String {
        rawValue.reduce(into: "") { result, character in
            guard character.isLetter || character.isNumber else { return }
            result.append(contentsOf: character.lowercased())
        }
    }
}

nonisolated extension EventName: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated enum Decision: String, Codable, CaseIterable, Sendable {
    case allow
    case allowAlways = "allow_always"
    case deny
    case `defer`
}

nonisolated struct HookRequest: Codable, Sendable {
    let id: UUID
    let eventName: EventName
    let source: String
    let cwd: String
    let threadName: String?
    let timeout: TimeInterval?
    let payload: [String: JSONValue]
    /// Where the agent that sent this is running. Not on the wire: the server works it out from
    /// the connecting process — see `AgentHostResolver` — so it is absent from `CodingKeys`.
    var host: AgentHost? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case eventName = "event_name"
        case source
        case cwd
        case threadName = "thread_name"
        case timeout
        case payload
    }

    /// The tool exactly as the agent named it.
    var rawToolName: String? {
        payloadValue(forKeys: ["tool_name", "toolname", "name"])?.stringValue
    }

    /// The tool under a label that means the same thing across agents. This is what the UI
    /// shows — `read_file` from one CLI and `Read` from another must not read as two tools.
    var toolName: String? {
        AgentTool.displayName(for: rawToolName)
    }

    /// What the current tool call *is*, independent of who named it. The session state machine
    /// keys off this: presenting a plan or asking a question is a different state from running
    /// a command, even though all three arrive as `PreToolUse`.
    var toolCategory: AgentTool.Category {
        AgentTool.category(of: rawToolName)
    }

    /// What the current tool call will do, in one line a person can read.
    ///
    /// Delegated to `AgentTool.inputSummary` rather than serialized: see the comment there for
    /// what the approval card used to show instead.
    var toolInputSummary: String? {
        guard let toolInput else { return nil }
        return AgentTool.inputSummary(category: toolCategory, input: toolInput)
    }

    var messageText: String? {
        payloadValue(
            forKeys: [
                "message", "permission_prompt", "prompt", "notification", "text",
                "last_assistant_message", "prompt_response", "reason",
            ]
        )?.compactSummary(limit: 500)
    }

    /// Where the agent is writing its transcript. Three CLIs, three spellings; jump-back and
    /// plan review both need it.
    var transcriptPath: String? {
        payloadValue(
            forKeys: ["transcript_path", "transcriptpath", "agent_transcript_path", "codex_transcript_path"]
        )?.stringValue
    }

    /// The working directory the agent reports, which is more trustworthy than the hook
    /// process's own cwd when the agent runs tools elsewhere.
    var reportedWorkingDirectory: String? {
        payloadValue(forKeys: ["cwd", "workspace_current_dir", "current_dir"])?.stringValue
    }

    var model: String? {
        payloadValue(
            forKeys: [
                // `modelname` is Antigravity's `modelName` (keys are matched lowercased).
                "codex_model", "resolvedmodel", "resolved_model", "model", "modelname",
                "model_name", "child_model",
            ]
        )?.stringValue
    }

    /// Which Codex client wrote a session-file record — see `CodexSessionReader`.
    var codexOriginator: String? {
        payload["originator"]?.stringValue
    }

    var reasoningEffort: String? {
        payloadValue(
            forKeys: ["codex_effort", "reasoning_effort", "child_reasoning_effort"]
        )?.stringValue
    }

    /// Claude's `Notification` events carry a kind; "idle" means the agent is waiting on the
    /// human rather than announcing something in passing.
    var notificationType: String? {
        payloadValue(forKeys: ["notification_type", "notificationtype"])?.stringValue
    }

    /// Why a `SessionStart` fired: Claude sends `startup`, `resume`, `clear` or `compact`.
    /// Not the request's own `source`, which names the agent CLI.
    var sessionStartSource: String? {
        payloadValue(forKeys: ["source"])?.stringValue
    }

    /// Present when the event came from a subagent rather than the main thread.
    var isSubagentEvent: Bool {
        agentID != nil || agentType != nil
    }

    /// The subagent's own identifier, when the event came from one.
    ///
    /// Verified against Claude Code 2.1.227 by capturing the live socket: a `Task` subagent's
    /// `PreToolUse`, `PostToolUse` and `SubagentStop` events all carry `agent_id` and
    /// `agent_type` *alongside the parent's `session_id`*. That is the whole reason the panel
    /// used to look like the machine was running five agents when it was running one with four
    /// helpers — every subagent tool call was landing on the parent's row.
    var agentID: String? {
        payloadValue(forKeys: ["agent_id", "agentid", "subagent_id"])?.stringValue
    }

    /// What kind of subagent it is — `Explore`, `general-purpose`, a custom agent's name.
    /// This is the child row's title, so it is the one piece of a subagent the user reads.
    var agentType: String? {
        payloadValue(forKeys: ["agent_type", "agenttype", "subagent_type"])?.stringValue
    }

    /// The subagent's own transcript, which is where its token usage lives. Distinct from
    /// `transcriptPath`, which resolves to the parent's file when both are present.
    var agentTranscriptPath: String? {
        payloadValue(forKeys: ["agent_transcript_path", "agenttranscriptpath"])?.stringValue
    }

    /// The tool call's input, exactly as the agent sent it. `toolInputSummary` reduces this to
    /// one line for display; answering a question has to send the whole object back.
    var toolInput: JSONValue? {
        payloadValue(
            forKeys: [
                "tool_input", "toolinput", "input", "arguments", "params",
                "permission_request", "permission_prompt",
            ]
        )
    }

    /// The question an `AskUserQuestion`-shaped tool call is asking, with its options — or
    /// `nil` for every other kind of approval.
    var approvalQuestion: ApprovalQuestion? {
        guard toolCategory == .question, let toolInput else { return nil }
        return ApprovalQuestion(toolInput: toolInput)
    }

    /// Set by the hook client when the agent is running on a remote host over SSH.
    var sshHost: String? {
        payloadValue(forKeys: ["_ssh_host"])?.stringValue
    }

    private func payloadValue(forKeys keys: [String]) -> JSONValue? {
        JSONValue.object(payload).firstValue(forKeys: keys)
    }
}

typealias HookEvent = HookRequest

nonisolated struct HookResponse: Codable, Sendable {
    let id: UUID
    let decision: Decision
    let reason: String?
    /// The tool input to run *instead of* the one the agent proposed, when the notch answered
    /// a question rather than merely allowing a call. See `ApprovalQuestion` and
    /// `tools/notch-hook/PROTOCOL.md`.
    let updatedInput: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id
        case decision
        case reason
        case updatedInput = "updated_input"
    }

    init(id: UUID, decision: Decision, reason: String? = nil, updatedInput: JSONValue? = nil) {
        self.id = id
        self.decision = decision
        self.reason = reason
        self.updatedInput = updatedInput
    }
}
