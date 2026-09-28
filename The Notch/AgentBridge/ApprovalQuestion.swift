import Foundation

/// A question an agent has stopped to ask, with the answers it is offering.
///
/// Some approvals are not permission at all. `AskUserQuestion` and its equivalents arrive
/// through the same `PermissionRequest` hook as a shell command does, so the notch was showing
/// the one surface it had — *Deny / Always Allow / Allow Once* — for a payload that contains a
/// question and four labelled answers. "Allow Once" on a question means nothing to the person
/// reading it: allow the agent to… ask? The agent then asks again in the terminal, which is the
/// place the notch exists to save you from going back to.
///
/// So a question is parsed out of the tool input and answered in the notch. The answer travels
/// back as `updatedInput` — the same tool call, with the `answers` map filled in — which is the
/// channel the CLI itself uses to satisfy an interaction without prompting.
///
/// Everything here is defensive. The payload is another program's schema and is allowed to
/// change: any shape this cannot read produces `nil`, and the card falls back to the ordinary
/// allow/deny buttons rather than showing an empty question.
nonisolated struct ApprovalQuestion: Equatable, Sendable {
    struct Option: Identifiable, Equatable, Sendable {
        /// Index in the offered order — the label is not guaranteed unique.
        let id: Int
        let label: String
        let detail: String?
    }

    /// The question itself. This is what the card leads with.
    let prompt: String
    /// The short chip the agent labelled the question with, when it sent one.
    let header: String?
    let options: [Option]
    /// True when the tool accepts more than one answer. The notch answers with one either way —
    /// see `ApprovalCardView` — but the label tells the user what they are giving up.
    let allowsMultiple: Bool
    /// The unmodified tool input, so an answer can be sent as *that call, answered* rather than
    /// as a reconstruction of it. Anything we did not parse survives the round trip.
    let originalInput: JSONValue

    /// Free text is always available: the CLI's own question UI offers an "Other" field, and a
    /// question the notch could only answer from a fixed list would be a downgrade.
    var acceptsFreeText: Bool { true }

    init?(toolInput: JSONValue) {
        guard let question = Self.firstQuestionObject(in: toolInput) else { return nil }
        guard let prompt = Self.text(question, keys: ["question", "prompt", "text"]),
              !prompt.isEmpty else {
            return nil
        }

        self.prompt = prompt
        header = Self.text(question, keys: ["header", "title", "label"])
        allowsMultiple = Self.bool(question, keys: ["multiSelect", "multiselect", "multi_select"])
            ?? false
        options = Self.parseOptions(in: question)
        originalInput = toolInput
    }

    /// The tool input with this answer filled in, ready to be sent back as `updatedInput`.
    ///
    /// Keyed by the question's own text, which is the key the tool's `answers` map uses. The
    /// original object is copied rather than rebuilt so a field we never looked at — an
    /// unfamiliar option flag, a metadata block — is still there when the call resumes.
    func answeredInput(with answer: String) -> JSONValue {
        guard case .object(var object) = originalInput else {
            return .object(["answers": .object([prompt: .string(answer)])])
        }
        var answers: [String: JSONValue]
        if case .object(let existing)? = object["answers"] {
            answers = existing
        } else {
            answers = [:]
        }
        answers[prompt] = .string(answer)
        object["answers"] = .object(answers)
        return .object(object)
    }

    /// Finds the object that carries the question, whether the payload wraps it in a
    /// `questions` array (the shape both CLIs send today) or is the question itself.
    private static func firstQuestionObject(in input: JSONValue) -> JSONValue? {
        if case .object(let object) = input {
            for key in ["questions", "question_list", "items"] {
                if case .array(let values)? = object[key], let first = values.first {
                    return first
                }
            }
            if object["question"] != nil || object["prompt"] != nil {
                return input
            }
        }
        if case .array(let values) = input, let first = values.first {
            return first
        }
        return nil
    }

    private static func parseOptions(in question: JSONValue) -> [Option] {
        guard case .object(let object) = question else { return [] }
        let raw: [JSONValue]
        if case .array(let values)? = object["options"] {
            raw = values
        } else if case .array(let values)? = object["choices"] {
            raw = values
        } else {
            return []
        }

        return raw.enumerated().compactMap { index, value in
            switch value {
            case .string(let label):
                let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return Option(id: index, label: trimmed, detail: nil)
            case .object:
                guard let label = text(value, keys: ["label", "title", "name", "value"]) else {
                    return nil
                }
                return Option(
                    id: index,
                    label: label,
                    detail: text(value, keys: ["description", "detail", "subtitle"])
                )
            default:
                return nil
            }
        }
    }

    private static func text(_ value: JSONValue, keys: [String]) -> String? {
        guard case .object(let object) = value else { return nil }
        for key in keys {
            guard let candidate = object[key]?.stringValue else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func bool(_ value: JSONValue, keys: [String]) -> Bool? {
        guard case .object(let object) = value else { return nil }
        for key in keys {
            if case .bool(let flag)? = object[key] { return flag }
        }
        return nil
    }
}
