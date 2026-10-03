import Foundation

/// Token usage for one session, read from the agent's own transcript.
nonisolated struct TranscriptUsage: Equatable, Sendable {
    /// How much context the session is currently carrying: the last assistant turn's input,
    /// plus everything it read from or wrote to the prompt cache.
    ///
    /// This is the number the panel leads with, because it is the one that means something at a
    /// glance — it is what fills up, and it is what the user is deciding about when they decide
    /// whether to keep going or start fresh. A cumulative token total looks alarming and says
    /// nothing: with a warm cache it climbs by 170k every single turn.
    var contextTokens: Int64?
    /// Everything the model has generated this session, summed across turns. Small, monotonic,
    /// and the honest measure of how much work has actually been done.
    var outputTokens: Int64?
    /// Cumulative billable input — fresh prompt tokens and cache writes, excluding cache reads.
    var inputTokens: Int64?
    /// Cost, when the transcript states one. Claude Code's does not; some agents' do, and it is
    /// strictly better than a number we would have to invent from a pricing table that goes
    /// stale the day a model ships.
    var costUSD: Double?
    /// The model behind the most recent turn. A level like `contextTokens`, not a total: the
    /// user can switch models mid-session, and the row should say what is answering now.
    var model: String?

    var isEmpty: Bool {
        contextTokens == nil && outputTokens == nil && inputTokens == nil && costUSD == nil
            && model == nil
    }
}

/// Reads token usage out of agent transcripts.
///
/// Hook payloads do not carry usage. Every event from Claude Code names its `transcript_path`
/// and nothing else, which is why the panel's usage column was empty on every row — the code
/// that reads it was correct and there was simply never anything to read. The transcript is a
/// JSONL file where each assistant line carries a `message.usage` object, so that is where the
/// numbers come from.
///
/// An actor, and incremental. A long session's transcript is tens of megabytes, and an event
/// arrives on every tool call; re-reading the file each time would spend more of the machine on
/// the status display than on the agent. Each path keeps a byte offset and only the bytes
/// appended since the last read are parsed. The one thing that has to be re-derived from the
/// tail rather than accumulated is the context size, which is a *level*, not a total — so the
/// last usage object seen wins.
actor TranscriptUsageReader {
    private struct State {
        var offset: UInt64 = 0
        var carry = Data()
        var usage = TranscriptUsage()
    }

    /// Lines longer than this are not transcript records we can use — a single pasted file, a
    /// base64 image — and buffering one whole is what would make this expensive.
    private static let maximumLineBytes = 4 * 1_024 * 1_024
    /// A guard against reading an unbounded amount in one pass when a transcript has grown a
    /// lot between events (a resumed session, a compaction rewrite).
    private static let maximumChunkBytes = 32 * 1_024 * 1_024

    private var states: [String: State] = [:]

    /// The usage known for a transcript after folding in whatever is new since the last call.
    /// Returns `nil` when the file is unreadable or carries no usage at all.
    func usage(forPath path: String) -> TranscriptUsage? {
        guard !path.isEmpty else { return nil }
        var state = states[path] ?? State()

        guard let handle = FileHandle(forReadingAtPath: path) else {
            states.removeValue(forKey: path)
            return nil
        }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        if size < state.offset {
            // The file shrank: it was rewritten, rotated, or replaced by a different session.
            // Anything accumulated describes a file that no longer exists.
            state = State()
        }

        let available = size - state.offset
        guard available > 0 else {
            states[path] = state
            return state.usage.isEmpty ? nil : state.usage
        }

        let start = available > UInt64(Self.maximumChunkBytes)
            ? size - UInt64(Self.maximumChunkBytes)
            : state.offset
        if start != state.offset { state.carry.removeAll() }

        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        state.offset = size

        var buffer = state.carry
        buffer.append(data)
        state.carry.removeAll()

        var searchStart = buffer.startIndex
        while let newline = buffer[searchStart...].firstIndex(of: 0x0A) {
            let line = buffer[searchStart ..< newline]
            searchStart = buffer.index(after: newline)
            fold(line: line, into: &state.usage)
        }
        // Whatever follows the last newline is a partial record; hold it for the next read.
        let remainder = buffer[searchStart...]
        if remainder.count <= Self.maximumLineBytes {
            state.carry = Data(remainder)
        }

        states[path] = state
        return state.usage.isEmpty ? nil : state.usage
    }

    /// Forgets a transcript. Called when its session leaves the panel, so a machine left running
    /// for a week does not keep one accumulator per session it has ever seen.
    func forget(path: String) {
        states.removeValue(forKey: path)
    }

    private func fold(line: Data.SubSequence, into usage: inout TranscriptUsage) {
        guard !line.isEmpty, line.count <= Self.maximumLineBytes else { return }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
        else { return }

        if let cost = Self.double(object["costUSD"] ?? object["cost_usd"]) {
            usage.costUSD = (usage.costUSD ?? 0) + cost
        }

        // Codex writes the model once per turn in a `turn_context` record rather than on
        // each message.
        if object["type"] as? String == "turn_context",
           let payload = object["payload"] as? [String: Any],
           let model = Self.modelName(payload["model"]) {
            usage.model = model
        }

        guard let message = object["message"] as? [String: Any] else { return }
        // Sidechain turns are subagents, which may run a cheaper model than the session.
        if (object["isSidechain"] as? Bool) != true, let model = Self.modelName(message["model"]) {
            usage.model = model
        }
        guard let raw = message["usage"] as? [String: Any] else { return }

        let input = Self.integer(raw["input_tokens"]) ?? 0
        let output = Self.integer(raw["output_tokens"]) ?? 0
        let cacheRead = Self.integer(raw["cache_read_input_tokens"]) ?? 0
        let cacheWrite = Self.integer(raw["cache_creation_input_tokens"]) ?? 0

        usage.outputTokens = (usage.outputTokens ?? 0) + output
        usage.inputTokens = (usage.inputTokens ?? 0) + input + cacheWrite

        // The context level belongs to the main thread of the conversation. A subagent's turns
        // are written into the parent's transcript flagged as a sidechain, and they carry their
        // own, much smaller context — letting one of those land here made the parent's context
        // appear to collapse and then jump back, every time a subagent spoke.
        let isSidechain = (object["isSidechain"] as? Bool) ?? false
        if !isSidechain {
            usage.contextTokens = input + cacheRead + cacheWrite
        }
    }

    /// Claude Code writes `<synthetic>` as the model of messages it generated itself (an
    /// interrupted turn, an API error), which is not a model anyone chose.
    private static func modelName(_ value: Any?) -> String? {
        guard let model = value as? String, !model.isEmpty, !model.hasPrefix("<") else { return nil }
        return model
    }

    private static func integer(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber:
            let value = number.int64Value
            return value >= 0 ? value : nil
        default:
            return nil
        }
    }

    private static func double(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let value = number.doubleValue
        return value.isFinite && value >= 0 ? value : nil
    }
}
