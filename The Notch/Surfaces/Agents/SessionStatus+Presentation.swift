import SwiftUI

/// How each session state is spelled in the notch.
///
/// Colour is the primary channel — at collapsed size a sprite is 8pt across and unreadable at a
/// glance, so hue has to carry the state on its own. The sprite and the label are what you get
/// once you actually look.
///
/// The nine states are deliberately not nine hues. The three "the agent is busy, do nothing"
/// states share a family, and the two "you are blocked" states share the warm end, so the
/// collapsed pill reads as one of three situations at a distance rather than as a colour code
/// the user has to learn.
extension SessionStatus {
    @MainActor
    var tint: Color {
        switch self {
        case .working: Theme.Colors.Status.working
        case .thinking: Theme.Colors.Status.thinking
        case .runningTool: Theme.Colors.Status.runningTool
        case .needsApproval: Theme.Colors.Status.needsApproval
        case .waitingForAnswer: Theme.Colors.Status.question
        case .waitingForInput: Theme.Colors.Status.waitingForInput
        case .compacting: Theme.Colors.Status.compacting
        case .done: Theme.Colors.Status.done
        case .idle: Theme.Colors.Status.idle
        }
    }

    /// `nil` where a plain dot says it better — a solid dot for a busy agent reads as a running
    /// process, whereas any sprite there reads as a thing you are supposed to click.
    var glyph: PixelGlyph? {
        switch self {
        case .needsApproval: .bang
        case .waitingForAnswer: .question
        case .done: .check
        case .working, .thinking, .runningTool, .waitingForInput, .compacting, .idle: nil
        }
    }

    var label: String {
        switch self {
        case .working: "Working"
        case .thinking: "Thinking"
        case .runningTool: "Running tool"
        case .needsApproval: "Needs approval"
        case .waitingForAnswer: "Waiting for answer"
        case .waitingForInput: "Waiting for input"
        case .compacting: "Compacting"
        case .done: "Done"
        case .idle: "Idle"
        }
    }

    /// One word, for the collapsed shoulder.
    ///
    /// The shoulder is ~109pt wide and the agent sprites take the first ~40 of it, so `label`
    /// does not fit: "Waiting for input" rendered as "waiting fo…", which truncates mid-word
    /// and tells the user less than a shorter word would have. This lives here rather than in
    /// the view so there is still exactly one status vocabulary — a second table growing
    /// beside this one is how the two drift apart.
    var shortLabel: String {
        switch self {
        case .working: "Working"
        case .thinking: "Thinking"
        case .runningTool: "Tool"
        case .needsApproval: "Approve"
        case .waitingForAnswer: "Asking"
        case .waitingForInput: "Waiting"
        case .compacting: "Compacting"
        case .done: "Done"
        case .idle: "Idle"
        }
    }

    /// Whether this state should light the attention ring around the collapsed silhouette.
    ///
    /// Only the two states where a run is genuinely stopped dead until the user acts. Notably
    /// *not* `waitingForInput`: a turn ending is the normal rhythm of working with an agent, and
    /// lighting the ring for it would leave the ring on almost permanently, which trains the
    /// user to ignore it and costs us the one signal that matters.
    var demandsAttention: Bool {
        switch self {
        case .needsApproval, .waitingForAnswer: true
        case .working, .thinking, .runningTool, .waitingForInput, .compacting, .done, .idle: false
        }
    }

    /// The agent is mid-turn and the user has nothing to do. Drives the pulse on the status dot.
    var isBusy: Bool {
        switch self {
        case .working, .thinking, .runningTool, .compacting: true
        case .needsApproval, .waitingForAnswer, .waitingForInput, .done, .idle: false
        }
    }
}
