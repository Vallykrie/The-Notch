import Foundation

/// Turns a model id into what a person calls the model.
///
/// `claude-opus-4-5-20251101` is precise and unreadable at a glance; the row has room for
/// "Opus 4.5". Ids the formatter does not recognise come back as they are rather than mangled —
/// a raw id is still more useful than a wrong name.
nonisolated enum ModelName {
    static func display(_ id: String) -> String {
        var raw = id.trimmingCharacters(in: .whitespacesAndNewlines)
        // Provider prefixes (`anthropic/…`, `us.anthropic.…`) and context suffixes (`[1m]`).
        if let slash = raw.lastIndex(of: "/") { raw = String(raw[raw.index(after: slash)...]) }
        if let bracket = raw.firstIndex(of: "[") { raw = String(raw[..<bracket]) }
        raw = raw.replacingOccurrences(of: "us.anthropic.", with: "")
            .replacingOccurrences(of: "anthropic.", with: "")

        let lower = raw.lowercased()
        if lower.hasPrefix("claude-") { return claude(String(lower.dropFirst("claude-".count))) }
        if lower.hasPrefix("gpt-") { return gpt(String(lower.dropFirst("gpt-".count))) }
        if lower.hasPrefix("gemini-") { return words("gemini-" + lower.dropFirst("gemini-".count)) }
        return raw
    }

    /// `opus-4-5-20251101` → `Opus 4.5`; the older `3-5-sonnet-20241022` → `Sonnet 3.5`.
    private static func claude(_ rest: String) -> String {
        let parts = rest.split(separator: "-").map(String.init).filter { !isDateStamp($0) }
        let family = parts.first { $0.first?.isLetter == true } ?? ""
        let version = parts.filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        guard !family.isEmpty else { return "Claude " + version }
        return [family.capitalized, version].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// `5.1-codex-max` → `GPT-5.1 Codex Max`.
    private static func gpt(_ rest: String) -> String {
        let parts = rest.split(separator: "-").map(String.init).filter { !isDateStamp($0) }
        guard let version = parts.first else { return "GPT" }
        let tail = parts.dropFirst().map(\.capitalized)
        return (["GPT-" + version] + tail).joined(separator: " ")
    }

    /// `gemini-2.5-pro` → `Gemini 2.5 Pro`.
    private static func words(_ id: String) -> String {
        id.split(separator: "-")
            .map { $0.first?.isNumber == true ? String($0) : $0.capitalized }
            .joined(separator: " ")
    }

    private static func isDateStamp(_ part: String) -> Bool {
        part.count == 8 && part.allSatisfy(\.isNumber)
    }
}
