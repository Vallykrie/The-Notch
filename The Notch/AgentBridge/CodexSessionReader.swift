import Foundation

nonisolated struct ObservedAgentEvent: Sendable {
    let request: HookRequest
    let date: Date
}

/// Read-only fallback shared by Codex desktop, IDE and CLI. Never changes hook trust.
/// Reads appended bytes off the UI actor; bootstrap reads only metadata and a bounded tail.
actor CodexSessionReader {
    private struct Cursor {
        var offset: UInt64 = 0
        var pending = Data()
        var id = ""
        var cwd = ""
        var modified = Date.distantPast
        var fileID: UInt64 = 0
        /// The model from the latest `turn_context`. Codex states it once per turn there and
        /// on no other record, so it is carried forward onto every event that follows.
        var model: String?
        /// `Codex Desktop`, `codex_cli_rs`, `codex_vscode` — which client started the session,
        /// from its first record. The only clue to where it runs: these sessions never pass
        /// through a hook, so there is no process to walk up from.
        var originator: String?
    }
    private let root: URL
    private var cursors: [URL: Cursor] = [:]
    private var candidates: [URL] = []
    private var scannedAt = Date.distantPast

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let codexHome = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        root = codexHome.appendingPathComponent("sessions")
    }

    func poll(now: Date = Date()) -> [ObservedAgentEvent] {
        if now.timeIntervalSince(scannedAt) >= 10 {
            scannedAt = now
            let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            var recent: [(URL, Date)] = []
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "jsonl", let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true, let date = values.contentModificationDate,
                      date > now.addingTimeInterval(-86400) else { continue }
                recent.append((url, date))
            }
            candidates = recent.sorted { $0.1 > $1.1 }.prefix(100).map(\.0)
            cursors = cursors.filter { candidates.contains($0.key) }
        }
        return candidates.flatMap { read($0, now: now) }.sorted { $0.date < $1.date }
    }

    private func read(_ url: URL, now: Date) -> [ObservedAgentEvent] {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let modified = attrs[.modificationDate] as? Date,
              let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let fileID = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        var cursor = cursors[url] ?? Cursor()
        if size < cursor.offset || cursor.fileID != fileID { cursor = Cursor() }
        let bootstrap = cursor.offset == 0
        guard bootstrap || modified != cursor.modified || size != cursor.offset else { return [] }
        if bootstrap {
            guard let head = try? handle.read(upToCount: 1 << 20),
                  let newline = head.firstIndex(of: 10),
                  let metadata = try? JSONSerialization.jsonObject(with: head.prefix(upTo: newline)) as? [String: Any],
                  let payload = metadata["payload"] as? [String: Any],
                  let id = payload["id"] as? String ?? payload["session_id"] as? String,
                  let cwd = payload["cwd"] as? String else { return [] }
            // Nested Codex agents are reported by their parent's lifecycle hooks.
            guard !(payload["source"] is [String: Any]) else { return [] }
            cursor.id = id
            cursor.cwd = cwd
            cursor.originator = payload["originator"] as? String
            cursor.offset = max(UInt64(newline + 1), size > 524288 ? size - 524288 : 0)
            if cursor.offset > UInt64(newline + 1) {
                try? handle.seek(toOffset: cursor.offset)
                if let fragment = try? handle.read(upToCount: 524288), let end = fragment.firstIndex(of: 10) {
                    cursor.offset += UInt64(end + 1)
                }
            }
        }
        try? handle.seek(toOffset: cursor.offset)
        guard let bytes = try? handle.read(upToCount: 2 << 20) else { return [] }
        cursor.offset += UInt64(bytes.count)
        cursor.pending.append(bytes)
        cursor.modified = modified
        cursor.fileID = fileID
        var events: [ObservedAgentEvent] = []
        while let end = cursor.pending.firstIndex(of: 10) {
            let line = cursor.pending.prefix(upTo: end)
            if let model = Self.turnModel(line) { cursor.model = model }
            if let event = Self.decode(line, id: cursor.id, cwd: cursor.cwd, model: cursor.model, originator: cursor.originator, fallbackDate: modified) { events.append(event) }
            cursor.pending.removeSubrange(...end)
        }
        // A very large tool output is not useful telemetry; retain neither its content nor
        // unbounded memory. Invalid fragments are ignored until the next complete record.
        if cursor.pending.count > 2 << 20 { cursor.pending.removeAll() }
        cursors[url] = cursor
        if bootstrap {
            guard let latest = events.last, latest.request.eventName != .stop,
                  latest.date > now.addingTimeInterval(-7200) else { return [] }
            return [latest]
        }
        return events
    }

    /// The model named by a `turn_context` record, or `nil` for any other line. A substring
    /// check first, so the common case — every other record — skips the JSON parse.
    nonisolated static func turnModel(_ data: Data) -> String? {
        guard data.range(of: Data("\"turn_context\"".utf8)) != nil,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "turn_context",
              let payload = root["payload"] as? [String: Any],
              let model = payload["model"] as? String, !model.isEmpty else { return nil }
        return model
    }

    nonisolated static func decode(_ data: Data, id: String, cwd: String, model: String? = nil, originator: String? = nil, fallbackDate: Date) -> ObservedAgentEvent? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["payload"] as? [String: Any] else { return nil }
        let type = payload["type"] as? String ?? ""
        let event: EventName
        var fields: [String: JSONValue] = ["_transport": .string("codex-session")]
        if let model { fields["model"] = .string(model) }
        if let originator { fields["originator"] = .string(originator) }
        switch root["type"] as? String {
        case "event_msg":
            switch type {
            case "task_started", "user_message": event = .userPromptSubmit
            case "task_complete", "task_completed", "turn_aborted": event = .stop
            case "agent_reasoning": event = .agentThought
            case "exec_approval_request", "apply_patch_approval_request": event = .elicitation
            default: return nil
            }
        case "response_item":
            switch type {
            case "function_call", "custom_tool_call":
                event = .preToolUse
                if let name = payload["name"] as? String { fields["tool_name"] = .string(name) }
            case "function_call_output", "custom_tool_call_output": event = .postToolUse
            case "reasoning": event = .agentThought
            default: return nil
            }
        default: return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = (root["timestamp"] as? String).flatMap { formatter.date(from: $0) } ?? fallbackDate
        return ObservedAgentEvent(request: HookRequest(id: UUID(), eventName: event, source: "codex", cwd: cwd, threadName: id, timeout: nil, payload: fields), date: date)
    }
}
