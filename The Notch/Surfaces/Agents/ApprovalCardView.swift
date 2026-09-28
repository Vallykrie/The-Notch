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
/// - **The actions can never be pushed off.** The detail line is the only flexible row, so a
///   long summary loses a line rather than pushing the buttons past the bottom curve.
@MainActor
struct ApprovalCardView: View {
    @ObservedObject var store: AgentSessionStore
    let approval: PendingApproval
    let namespace: Namespace.ID

    /// What the user typed into the free-text answer. Local view state: an answer that has not
    /// been sent yet is not part of the approval, and it must not survive the card.
    @State private var typedAnswer = ""
    @FocusState private var isTypingAnswer: Bool

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
                    actions
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
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
    /// than pushing the buttons past the panel's bottom curve, which is what used to happen.
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

    /// Wording follows the vocabulary these agents already use in the terminal, so the notch
    /// and the CLI do not disagree about what a button means.
    private var actions: some View {
        HStack(spacing: Theme.Metrics.collapsedContentSpacing) {
            Button("Deny", role: .destructive) {
                resolve(.deny)
            }
            .buttonStyle(.notch)
            .keyboardShortcut(.escape, modifiers: [])

            Spacer(minLength: Theme.Metrics.collapsedContentSpacing)

            Button("Always Allow") {
                resolve(.allowAlways)
            }
            .buttonStyle(.notch)

            Button("Allow Once") {
                resolve(.allow)
            }
            .buttonStyle(.notch)
            .tint(Theme.Colors.Status.working)
            .keyboardShortcut(.return, modifiers: [])
        }
    }

    /// The question's own answers, which is the whole point of the surface.
    ///
    /// Everything about this row is sized by the fact that the panel is 190pt tall and the
    /// header has already taken a third of it. The options are one line each, the free-text
    /// field is one more, and the list scrolls only if the agent offered more answers than fit
    /// — `ViewThatFits` so the common case pays no scroll gutter, the same trick and the same
    /// reason as `AgentsExpandedView`.
    @ViewBuilder
    private var answerChoices: some View {
        if let question {
            VStack(alignment: .leading, spacing: Theme.Metrics.Agents.optionSpacing) {
                // The options scroll and the field does not, which is the only split that
                // survives every question an agent can ask. Four options and a text field do
                // not fit in a 190pt panel at a legible size — the panel is one notch tall and
                // that is not negotiable — and of the two, the field is the one that must never
                // be the thing you have to scroll to find: it is how you answer anything the
                // agent did not think to offer. So the list gives, and it gives from the end,
                // where the least likely answers are.
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Metrics.Agents.optionSpacing) {
                        ForEach(question.options) { option in
                            optionRow(option)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: .infinity)

                freeTextRow
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// One answer. The number on the right is the key that picks it, mirroring the numbered
    /// list the CLI prints — the notch should not teach a second set of shortcuts for the same
    /// question. Only the first nine are bound, because there is no tenth key.
    private func optionRow(_ option: ApprovalQuestion.Option) -> some View {
        Button {
            answer(option.label)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.expandedContentSpacing) {
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

                Spacer(minLength: Theme.Metrics.collapsedContentSpacing)

                Text("\(option.id + 1)")
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.notchCompact)
        .modifier(OptionShortcut(index: option.id))
        .accessibilityLabel(
            [option.label, option.detail].compactMap { $0 }.joined(separator: ": ")
        )
    }

    /// The "Other" field. Present even when the agent offered good options, because the CLI's
    /// own question UI has one and a notch that could only pick from a list would be a reason
    /// to go back to the terminal — which is the single thing this surface exists to avoid.
    private var freeTextRow: some View {
        HStack(spacing: Theme.Metrics.collapsedContentSpacing) {
            TextField("Type your own answer", text: $typedAnswer)
                .textFieldStyle(.plain)
                .font(Theme.Text.body)
                .foregroundStyle(Theme.Colors.textPrimary)
                // The caret and the selection, which otherwise take the system accent colour —
                // whatever the user has chosen in System Settings, painted across a field on a
                // pure-black panel that owns its whole palette.
                .tint(Theme.Colors.textPrimary)
                .focused($isTypingAnswer)
                .onSubmit { answer(typedAnswer) }
                .padding(.horizontal, Theme.Metrics.Control.horizontalPadding)
                .padding(.vertical, Theme.Metrics.Control.verticalPadding)
                .background(
                    RoundedRectangle(
                        cornerRadius: Theme.Metrics.Control.cornerRadius,
                        style: .continuous
                    )
                    .fill(.white.opacity(Theme.Metrics.Control.fillOpacity))
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: Theme.Metrics.Control.cornerRadius,
                        style: .continuous
                    )
                    .strokeBorder(
                        .white.opacity(Theme.Metrics.Control.borderOpacity),
                        lineWidth: Theme.Metrics.Control.borderWidth
                    )
                )

            // Deliberately not "Cancel". Deferring hands the question back to the CLI, which
            // asks it there exactly as it would have without the notch — nothing is refused
            // and the agent keeps its turn.
            Button("Ask in terminal") {
                resolve(.defer)
            }
            .buttonStyle(.notch)
            .keyboardShortcut(.escape, modifiers: [])

            Button("Send") {
                answer(typedAnswer)
            }
            .buttonStyle(.notch)
            .tint(Theme.Colors.Status.working)
            .keyboardShortcut(.return, modifiers: [])
            .disabled(nonEmpty(typedAnswer) == nil)
        }
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

    private func answer(_ text: String) {
        guard let text = nonEmpty(text) else { return }
        store.answer(approvalID: approval.approvalID, with: text)
    }

    private func resolve(_ decision: Decision) {
        store.resolve(approvalID: approval.approvalID, decision: decision)
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

/// Binds `1`…`9` to the first nine options, and nothing to any beyond them.
///
/// A separate modifier rather than an inline `if` at the call site: `keyboardShortcut` returns
/// a different view type than the view it is applied to, so branching around it in the row
/// builder would give the button two identities and drop its press state as the list changed.
private struct OptionShortcut: ViewModifier {
    let index: Int

    func body(content: Content) -> some View {
        if index < 9, let key = "123456789".dropFirst(index).first {
            content.keyboardShortcut(KeyEquivalent(key), modifiers: [])
        } else {
            content
        }
    }
}
