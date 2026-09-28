import SwiftUI

/// One sprite for everything the agents are doing.
///
/// This was a row of up to three sprites beside a status word, all on one shoulder. Two things
/// were wrong with it. It needed ~134pt against ~109pt of usable shoulder, so it overflowed
/// underneath the camera housing; and three sprites is a *census*, which is what the expanded
/// panel is for. The collapsed notch answers "is anything running, and does it want me" — one
/// glyph in one hue answers that completely.
///
/// It used to be the *agent's* sprite — a Claude burst, a Codex chevron — tinted by the
/// dominant status. That answered the wrong question. Which agent it is does not change while
/// you look at it, and it is a fact the expanded panel already states plainly on every row;
/// what the collapsed notch exists to answer is *what is happening*, and the sprite could only
/// say that through its hue. So the one mark on the shoulder was static by construction: an
/// unchanging shape whose colour changed occasionally, which is precisely as much as a
/// peripheral glance could ever get out of it.
///
/// It is now the state's own motion (`AgentActivityGlyph`), which is a channel that survives
/// being 8pt across at the top of the display: a shape you cannot resolve still reads
/// unmistakably as sweeping, or bouncing, or blinking. The agent's identity moves to the
/// accessibility label and the expanded row, where it can be read rather than guessed.
///
/// The mark shows the *leading* session's own state, and the leading session is whichever one
/// the user last spoke to — or whichever one is blocked on them, which always outranks it.
///
/// It used to show a dominant-status election across every live session, on the reasoning that
/// one mark showing one session's state misreports the others. That is true and it is the wrong
/// trade: an election has no subject, so the shoulder was reporting a mood rather than a thing.
/// The user's own reading is the one that settles it — the sprite should be *the agent I just
/// gave work to* — and it is also the only reading where clicking the notch takes you to the
/// row the sprite was describing, because the leading session is the row at the top of the
/// panel. What the other sessions are doing is one hover away, itemised, which is exactly the
/// division of labour between the collapsed notch and the expanded panel.
///
/// Used on the *leading* shoulder in `.agentsOnly` and on the *trailing* shoulder in `.both`.
/// It carries no frame or alignment of its own — the shoulder it lands on owns that, because
/// only the shoulder knows which edge is the outer one.
@MainActor
struct AgentsCollapsedView: View {
    @ObservedObject var store: AgentSessionStore

    @ViewBuilder
    var body: some View {
        if let session = store.leadingSession {
            let status = session.status
            AgentActivityGlyphView(
                status: status,
                side: Theme.Metrics.Agents.mascotCollapsedSize,
                identity: session.id,
                lastActivity: session.lastActivity
            )
            .foregroundStyle(status.tint)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(session.kind.displayName): \(status.label)")
        }
    }
}

/// How many agents are live, opposite the sprite in `.agentsOnly`.
///
/// A count, not a status word. The word used to live here *beside* the sprites, which meant the
/// shoulder said the same thing twice — the hue already carries the state. What the hue cannot
/// say is how many, so that is what this says.
///
/// Except when something is blocked. A pending approval, then a pending question, still outrank
/// the count: those are the only two states where the notch is asking for something rather than
/// reporting, and burying "3 waiting on you" under "3 agents" is how a signal gets ignored.
@MainActor
struct AgentsCountCollapsedView: View {
    @ObservedObject var store: AgentSessionStore

    var body: some View {
        readout
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var readout: some View {
        if !store.pendingApprovals.isEmpty {
            badge(
                glyph: .bang,
                count: store.pendingApprovals.count,
                tint: Theme.Colors.Status.needsApproval
            )
        } else if let waitingCount {
            badge(
                glyph: .question,
                count: waitingCount,
                tint: Theme.Colors.Status.question
            )
        } else {
            // The bare number, with no "agent"/"agents" beside it.
            //
            // The word cost ~46pt of shoulder to restate what the sprite across the housing
            // already establishes, and the shoulder is now 40pt wide in total. It is not a
            // truncation: the noun is carried by the sprite opposite, the state by that
            // sprite's hue, and the only thing left for this shoulder to say is *how many* —
            // which is a digit. VoiceOver still gets the full sentence below.
            //
            // Deliberately untinted, for the same reason the word was: the hue lives on one
            // shoulder only, or the count becomes a second status readout.
            Text("\(sessionCount)")
                .font(Theme.Text.caption)
                .contentTransition(.numericText())
        }
    }

    private func badge(glyph: PixelGlyph, count: Int, tint: Color) -> some View {
        HStack(spacing: Theme.Metrics.collapsedContentSpacing) {
            PixelGlyphView(glyph: glyph, side: Theme.Metrics.glyphCollapsedSize)
            Text("\(count)")
                .font(Theme.Text.caption)
                .contentTransition(.numericText())
        }
        .foregroundStyle(tint)
    }

    private var sessionCount: Int {
        store.sessions.count
    }

    /// Counts `waitingForAnswer`, not `waitingForInput`. Those used to be the same case; once
    /// they split, `waitingForInput` came to mean "the turn ended", which is the normal rhythm
    /// of a session and would leave this badge lit almost permanently. The badge is for a
    /// question that is actually on screen waiting to be answered.
    private var waitingCount: Int? {
        let count = store.sessions.count { $0.status == .waitingForAnswer }
        return count > 0 ? count : nil
    }

    private var accessibilityLabel: String {
        if !store.pendingApprovals.isEmpty {
            "\(store.pendingApprovals.count) pending approval"
        } else if let waitingCount {
            "\(waitingCount) waiting for answer"
        } else {
            "\(sessionCount) agent\(sessionCount == 1 ? "" : "s") running"
        }
    }
}

/// The two elections the collapsed shoulders run, in one place. They live on the store rather
/// than in either view because the sprite and the count sit on *opposite* shoulders now and
/// would otherwise each keep their own copy — which is how two readouts about the same agents
/// drift apart.
private extension AgentSessionStore {
    /// Whatever is blocking the user comes first, so the one sprite on screen is always the one
    /// worth clicking. Failing that it is `sessions.first`, which is the session the user last
    /// typed into — see `AgentSessionStore.sessions` for why that beats the busiest one.
    var leadingSession: AgentSession? {
        guard let blockingSessionID = oldestApproval?.sessionID,
              let blockingSession = session(for: blockingSessionID) else {
            return sessions.first
        }

        return blockingSession
    }

    var oldestApproval: PendingApproval? {
        pendingApprovals.min { $0.requestedAt < $1.requestedAt }
    }
}
