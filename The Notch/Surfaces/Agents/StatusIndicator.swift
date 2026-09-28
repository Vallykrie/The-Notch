import SwiftUI

/// Shared identifiers and metrics for the agent surfaces.
@MainActor
enum AgentSurfaceElement {
    static func status(sessionID: String) -> String {
        "agent-status-\(sessionID)"
    }
}

/// What a session is doing, as a mark.
///
/// This was a filled `Circle` in `status.tint`, scale-pulsing on one shared spring whenever
/// `status.isBusy`, with a static 1.7x halo ring around it for `needsApproval`. Three things
/// were wrong with that and only one of them was the halo:
///
/// - **The four busy states were the same animation.** Working, thinking, running a tool and
///   compacting all got one pulse at one rate, so the mark said "busy" and the hue said which
///   kind of busy — and hue is the channel this surface can least afford to spend, because it
///   is already carrying urgency and it is the channel that fails in peripheral vision.
/// - **The five non-busy states had no animation at all.** A dot for "done", a dot for "idle",
///   a dot for "waiting for input", each distinguishable only by a colour the user has to have
///   learned. That is the "static, just a different colour" the whole indicator read as.
/// - **The halo was a static ring at a fixed 1.7x**, so the one state that most needed to be
///   noticed was the one drawn as a slightly larger unmoving target.
///
/// It is now `AgentActivityGlyphView`, which gives each state its own motion. The type survives
/// under its old name because `SessionRowView` matches geometry against it across the collapse.
@MainActor
struct StatusIndicator: View {
    let status: SessionStatus
    let size: CGFloat
    /// Passed through to the mascot — see `AgentActivityGlyphView.identity`.
    var identity: String?
    var lastActivity: Date?

    var body: some View {
        AgentActivityGlyphView(status: status, side: size, identity: identity, lastActivity: lastActivity)
            .foregroundStyle(status.tint)
    }
}
