import SwiftUI

/// The panel while an agent is blocked on a permission decision.
///
/// This is the surface with the tightest vertical budget in the app and the shortest time to
/// read: the notch is 190pt tall, the card is the only thing in it, and the user is looking at
/// it because something stopped. Three things follow from that, and all three are why this
/// stopped being a bordered "card" drawn inside the panel:
///
/// - **The panel is the card.** `AgentsExpandedView` shows this *instead of* the session list,
///   and the shell already draws an amber attention ring around the whole silhouette. A second
///   amber rounded rectangle 12pt inside the first one was a frame around a frame, and it cost
///   24pt of height — a quarter of the budget — to say something already said. The accent
///   survives as a rule down the leading edge, which costs nothing vertically.
/// - **The heading was the wrong line.** "Approval needed" was set at `headline` while the
///   tool name — the only part that differs between one of these and the next — sat below it a
///   size down. Whether approval is needed is answered by the ring, the mascot and three
///   buttons; *what* is being approved is answered by nothing else, so it takes the headline.
/// - **It is a notice, not a form.** The notch announces the prompt; the answer is given in the
///   agent's own terminal, which the hook hands the decision straight back to. Tapping the card
///   dismisses it, for a prompt answered in a way that emitted no event to clear it.
@MainActor
struct ApprovalCardView: View {
    @ObservedObject var store: AgentSessionStore
    let approval: PendingApproval
    let namespace: Namespace.ID


    private var question: ApprovalQuestion? { approval.question }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.Agents.cardPadding) {
            accentRule

            VStack(alignment: .leading, spacing: Theme.Metrics.collapsedContentSpacing) {
                header
                if question != nil {
                    answerChoices
                } else {
                    summary
                }
                terminalHint
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { store.dismissApproval(approvalID: approval.approvalID) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Dismiss") {
            store.dismissApproval(approvalID: approval.approvalID)
        }
    }

    /// What the bordered card's stroke used to say, in a shape that spends no height.
    private var accentRule: some View {
        Capsule(style: .continuous)
            .fill(accent)
            .frame(width: Theme.Metrics.Agents.accentRuleWidth)
            .frame(maxHeight: .infinity)
            .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(spacing: Theme.Metrics.expandedContentSpacing) {
            // Same reasoning as `SessionRowView`: the agent's own sprite beside the status
            // mark was two icons doing one job. Here it mattered more — this card is the one
            // place in the app that has to be understood in a glance from across a desk.
            StatusIndicator(
                status: question == nil ? .needsApproval : .waitingForAnswer,
                size: question == nil
                    ? Theme.Metrics.Agents.activityGlyphSize
                    : Theme.Metrics.Agents.questionGlyphSize
            )
            .accessibilityLabel("\(approval.kind.displayName): \(statusWord.lowercased())")
            .matchedGeometryEffect(
                id: AgentSurfaceElement.status(sessionID: approval.sessionID),
                in: namespace
            )

            VStack(alignment: .leading, spacing: 2) {
                // Truncated in the middle, not at the tail: an MCP tool reads
                // `github: create_pull_request`, and both halves carry meaning.
                // A question leads with the question itself. The tool's name is the only
                // thing that differs between one *permission* prompt and the next, but between
                // one question and the next it is always `AskUserQuestion` — the sentence the
                // agent is asking is what the user has to read, so it takes the headline.
                // A question is set a size down from a permission prompt's tool name, and that
                // is a budget decision rather than a hierarchy one: the answers underneath are
                // the part that has to fit, and at `headline` a two-line question ate the room
                // for two of them. It is still the largest thing on the card.
                Text(headline)
                    .font(question == nil ? Theme.Text.headline : Theme.Text.title)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(2)
                    .truncationMode(question == nil ? .middle : .tail)
                    .fixedSize(horizontal: false, vertical: true)

                // The subtitle survives only on a permission prompt. On a question the same row
                // would restate the header chip and the project while the answers below are
                // fighting for height — and the panel is answering a sentence, not filing it.
                if question == nil {
                    HStack(spacing: 5) {
                        Text(statusWord)
                            .foregroundStyle(accent)
                        Text("·")
                            .foregroundStyle(Theme.Colors.textTertiary)
                        Text(approval.projectDisplayName)
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .truncationMode(.middle)
                    }
                    .font(Theme.Text.body)
                    .lineLimit(1)
                }
            }

            Spacer(minLength: Theme.Metrics.collapsedContentSpacing)

            // One line, not two. The chip sits beside the clock rather than under it because
            // the row's height is the answers' height: every point spent stacking two short
            // labels here is a point the option list does not get.
            HStack(spacing: 5) {
                if question != nil {
                    Text(statusWord)
                        .font(Theme.Text.body)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .lineLimit(1)
                    Text("·")
                        .font(Theme.Text.body)
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
                elapsed
            }
        }
    }

    /// How long the agent has been stopped, at a width that does not move.
    ///
    /// `Text(_:style: .relative)` renders "21 min, 7 secs" — eighteen characters that grow and
    /// shrink every second in a monospace font, next to a project name that is already fighting
    /// for the same row. The number matters as an order of magnitude, not to the second.
    private var elapsed: some View {
        TimelineView(
            .periodic(
                from: approval.requestedAt,
                by: Theme.Metrics.Agents.elapsedRefreshInterval
            )
        ) { context in
            Text("blocked \(Self.elapsedLabel(context.date.timeIntervalSince(approval.requestedAt)))")
                .font(Theme.Text.body)
                .foregroundStyle(accent)
                .lineLimit(1)
                .accessibilityLabel("Blocked since \(approval.requestedAt.formatted())")
        }
    }

    /// The only row that flexes. A negative layout priority hands the fixed rows their height
    /// first, so this is what gives when the summary is long — losing a line of detail, rather
    /// than pushing the hint past the panel's bottom curve.
    @ViewBuilder
    private var summary: some View {
        Group {
            if let text = nonEmpty(approval.toolInputSummary) ?? nonEmpty(approval.message) {
                Text(text)
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(Theme.Metrics.Agents.summaryLineLimit)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .layoutPriority(-1)
    }

    /// Where the answer goes. The notch only announces; the agent's own prompt decides — so
    /// the hint is also the way there: it brings the agent's window forward. A `Button`, so its
    /// click is not also taken by the card's tap-to-dismiss.
    private var terminalHint: some View {
        HStack(spacing: 4) {
            if let session = store.session(for: approval.sessionID),
               SessionWindowOpener.canOpen(session) {
                Button {
                    SessionWindowOpener.open(session)
                } label: {
                    HStack(spacing: 4) {
                        PixelGlyphView(glyph: .openWindow, side: Theme.Metrics.Settings.dismissGlyphSize)
                        Text("Open Agent to answer")
                    }
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(session.host.map { "Open \($0.name)" } ?? "Open \(session.kind.displayName)")

                Text("· click elsewhere to dismiss")
                    .foregroundStyle(Theme.Colors.textTertiary)
            } else {
                Text("Respond in the terminal · click to dismiss")
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
        }
        .font(Theme.Text.caption)
        .lineLimit(1)
    }

    /// The answers the agent is offering, read-only — they are picked in the terminal.
    @ViewBuilder
    private var answerChoices: some View {
        if let question {
            // Not scrollable: nothing here is interactive, and the tail options the panel has no
            // room for are still listed in the terminal where they are picked.
            VStack(alignment: .leading, spacing: Theme.Metrics.Agents.optionSpacing) {
                ForEach(question.options) { option in
                    optionRow(option)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .layoutPriority(-1)
        }
    }

    /// One answer, numbered as the CLI numbers it so the key to press there is obvious.
    private func optionRow(_ option: ApprovalQuestion.Option) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.expandedContentSpacing) {
            Text("\(option.id + 1).")
                .font(Theme.Text.caption)
                .foregroundStyle(Theme.Colors.textTertiary)

            Text(option.label)
                .font(Theme.Text.body)
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            if let detail = nonEmpty(option.detail) {
                Text(detail)
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [option.label, option.detail].compactMap { $0 }.joined(separator: ": ")
        )
    }

    private var headline: String {
        if let question {
            return question.prompt
        }
        return nonEmpty(approval.toolName) ?? "Approval needed"
    }

    private var statusWord: String {
        guard let question else { return "Approval needed" }
        if let header = nonEmpty(question.header) { return header }
        return "Question"
    }

    /// Amber for a decision that is holding a hook open, the question hue for one that is
    /// waiting on a sentence. They are different states everywhere else in the app — see
    /// `SessionStatus` — and the card is the one place the difference is most worth keeping.
    private var accent: Color {
        question == nil
            ? Theme.Colors.Status.needsApproval
            : Theme.Colors.Status.question
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Seconds while seconds are what you have been waiting, then minutes, then hours. Never
    /// more than four characters wide.
    static func elapsedLabel(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        guard seconds >= 60 else { return "\(seconds)s" }
        let minutes = seconds / 60
        guard minutes >= 60 else { return "\(minutes)m" }
        let hours = minutes / 60
        guard hours >= 24 else { return "\(hours)h\(minutes % 60)m" }
        return "\(hours / 24)d"
    }
}
