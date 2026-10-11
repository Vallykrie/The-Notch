import SwiftUI

/// The panel while an agent is blocked on a permission decision or a question.
///
/// It is a notice, not a form: the answer is given in the agent itself, which the hook hands
/// the decision straight back to (approving from the notch did not land reliably in Claude
/// Code, so it was removed). The card's job is therefore to make three things obvious at a
/// glance — what is being asked, what the choices are, and how to get to where you answer.
///
/// The layout is two columns (`docs/design/approval-question-layouts-v1.html`, layout A):
///
/// - **Who**, on the left: the mascot at a size where its startle reads, what kind of prompt
///   this is, the agent, the project, and how long it has been waiting. This column sits
///   beside the camera housing rather than under it, so it can start at the top of the panel.
/// - **What**, on the right: the tool and its command in a code block, or the question with its
///   options as a grid of numbered chips — each option's description on a line of its own,
///   because squeezed beside the label it was always the part that got cut off.
/// - **The way there**, along the bottom: a real "Answer in …" button that brings the agent's
///   window forward, the key to press once there, and an explicit dismiss.
///
/// The panel's tab bar is hidden while this shows (see `NotchRootView.showsHeader`), so the
/// card is the whole panel. The right column starts below the camera housing, because with no
/// tab bar above it the top centre of the panel is hardware.
@MainActor
struct ApprovalCardView: View {
    @ObservedObject var store: AgentSessionStore
    let approval: PendingApproval
    let namespace: Namespace.ID

    @Environment(\.notchLayout) private var notchLayout

    private var question: ApprovalQuestion? { approval.question }
    private var metrics: Theme.Metrics.Prompt.Type { Theme.Metrics.Prompt.self }

    var body: some View {
        HStack(alignment: .top, spacing: metrics.columnSpacing) {
            // The accent down the leading edge: the one stroke of colour that says "blocked"
            // before anything is read.
            Capsule(style: .continuous)
                .fill(accent)
                .frame(width: metrics.ruleWidth)
                .frame(maxHeight: .infinity)
                .padding(.top, metrics.whoTopInset)
                .padding(.trailing, metrics.ruleGap - metrics.columnSpacing)
                .accessibilityHidden(true)

            who
                .frame(width: metrics.whoColumnWidth, alignment: .leading)
                .padding(.top, metrics.whoTopInset)

            VStack(alignment: .leading, spacing: Theme.Metrics.collapsedContentSpacing) {
                if question != nil {
                    questionBody
                } else {
                    permissionBody
                }
                Spacer(minLength: .zero)
                actions
            }
            .padding(.top, whatTopInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, metrics.bottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Dismiss") {
            store.dismissApproval(approvalID: approval.approvalID)
        }
    }

    /// Below the camera housing on a notched Mac; the panel's own top inset otherwise.
    private var whatTopInset: CGFloat {
        notchLayout.hasPhysicalNotch
            ? notchLayout.physicalNotchSize.height + metrics.housingClearance
            : metrics.whoTopInset
    }

    // MARK: Who

    private var who: some View {
        VStack(alignment: .leading, spacing: metrics.whoSpacing) {
            StatusIndicator(
                status: question == nil ? .needsApproval : .waitingForAnswer,
                size: metrics.mascotSize
            )
            .accessibilityLabel("\(approval.kind.displayName): \(kindLabel.lowercased())")
            .mascotAnchor(.card)
            .matchedGeometryEffect(
                id: AgentSurfaceElement.status(sessionID: approval.sessionID),
                in: namespace
            )
            .padding(.bottom, metrics.whoSpacing)

            Text(kindLabel.uppercased())
                .font(Theme.Text.micro)
                .foregroundStyle(accent)
                .lineLimit(1)

            VStack(alignment: .leading, spacing: 1) {
                Text(approval.kind.displayName)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(approval.projectDisplayName)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .truncationMode(.middle)
            }
            .font(Theme.Text.body)
            .lineLimit(1)

            waiting
        }
    }

    private var kindLabel: String {
        question == nil ? "Needs permission" : "Has a question"
    }

    /// How long the agent has been stopped, at a width that does not move — see
    /// `elapsedLabel`.
    private var waiting: some View {
        TimelineView(.periodic(from: approval.requestedAt, by: Theme.Metrics.Agents.elapsedRefreshInterval)) { context in
            Text("waiting \(Self.elapsedLabel(context.date.timeIntervalSince(approval.requestedAt)))")
                .font(Theme.Text.micro)
                .foregroundStyle(Theme.Colors.textTertiary)
                .lineLimit(1)
                .accessibilityLabel("Waiting since \(approval.requestedAt.formatted())")
        }
    }

    // MARK: What

    /// The tool, what it is for, and the command itself in a code block. The tool's name is the
    /// only part that differs between one of these and the next, so it takes the headline.
    private var permissionBody: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.collapsedContentSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.collapsedContentSpacing) {
                Text(nonEmpty(approval.toolName) ?? "Approval needed")
                    .font(Theme.Text.headline)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if let purpose = purpose {
                    Text(purpose)
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .lineLimit(1)
                }
            }

            if let command = nonEmpty(approval.toolInputSummary) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("$")
                        .foregroundStyle(Theme.Colors.textTertiary)
                    Text(command)
                        .foregroundStyle(metrics.commandTint)
                        .lineLimit(metrics.commandLineLimit)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(Theme.Text.body)
                .padding(.horizontal, metrics.blockHorizontalPadding)
                .padding(.vertical, metrics.blockVerticalPadding)
                .background(
                    RoundedRectangle(cornerRadius: metrics.blockCornerRadius, style: .continuous)
                        .fill(Theme.Colors.textPrimary.opacity(metrics.blockFillOpacity))
                )
            }
        }
    }

    /// The agent's own description of the call, when it gave one that is not just the command
    /// again.
    private var purpose: String? {
        guard let message = nonEmpty(approval.message), message != nonEmpty(approval.toolInputSummary) else { return nil }
        return message
    }

    /// The question, then its options as a grid — two columns once there are more than two, so
    /// four options fit in two rows with room for a description under each label.
    @ViewBuilder
    private var questionBody: some View {
        if let question {
            VStack(alignment: .leading, spacing: Theme.Metrics.collapsedContentSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.collapsedContentSpacing) {
                    if let header = nonEmpty(question.header) {
                        Text(header)
                            .font(Theme.Text.micro)
                            .foregroundStyle(accent)
                            .padding(.horizontal, metrics.tagHorizontalPadding)
                            .overlay(
                                RoundedRectangle(cornerRadius: metrics.tagCornerRadius, style: .continuous)
                                    .strokeBorder(accent.opacity(0.4), lineWidth: 1)
                            )
                    }
                    Text(question.prompt)
                        .font(Theme.Text.title)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: metrics.chipSpacing), count: question.options.count > 2 ? 2 : max(question.options.count, 1)),
                    alignment: .leading,
                    spacing: metrics.chipSpacing
                ) {
                    ForEach(visibleOptions(of: question)) { option in
                        optionChip(option)
                    }
                    if question.options.count > metrics.maxVisibleOptions {
                        moreChip(question.options.count - metrics.maxVisibleOptions + 1)
                    }
                }
            }
        }
    }

    /// Four chips fit; past that the last slot says how many more are waiting in the terminal.
    private func visibleOptions(of question: ApprovalQuestion) -> [ApprovalQuestion.Option] {
        guard question.options.count > metrics.maxVisibleOptions else { return question.options }
        return Array(question.options.prefix(metrics.maxVisibleOptions - 1))
    }

    /// One answer, numbered as the CLI numbers it so the key to press there is obvious.
    private func optionChip(_ option: ApprovalQuestion.Option) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.collapsedContentSpacing) {
                Text("\(option.id + 1)")
                    .foregroundStyle(accent)
                Text(option.label)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .truncationMode(.tail)
            }
            .font(Theme.Text.body)
            .lineLimit(1)

            if let detail = nonEmpty(option.detail) {
                Text(detail)
                    .font(Theme.Text.micro)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, metrics.chipHorizontalPadding)
        .padding(.vertical, metrics.chipVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: metrics.blockCornerRadius, style: .continuous)
                .fill(Theme.Colors.textPrimary.opacity(metrics.blockFillOpacity))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([option.label, option.detail].compactMap { $0 }.joined(separator: ": "))
    }

    private func moreChip(_ count: Int) -> some View {
        Text("+\(count) more in the terminal")
            .font(Theme.Text.caption)
            .foregroundStyle(Theme.Colors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, metrics.chipHorizontalPadding)
            .padding(.vertical, metrics.chipVerticalPadding)
    }

    // MARK: The way there

    private var actions: some View {
        HStack(spacing: Theme.Metrics.collapsedContentSpacing * 1.5) {
            if let session = store.session(for: approval.sessionID), SessionWindowOpener.canOpen(session) {
                Button {
                    SessionWindowOpener.open(session)
                } label: {
                    Text("Answer in \(approval.kind.displayName) ↗")
                }
                .buttonStyle(PromptPrimaryButtonStyle(tint: accent))
                .help(session.host.map { "Open \($0.name)" } ?? "Open \(session.kind.displayName)")
            }

            Text(keyHint)
                .font(Theme.Text.micro)
                .foregroundStyle(Theme.Colors.textTertiary)
                .lineLimit(1)

            Spacer(minLength: .zero)

            Button {
                store.dismissApproval(approvalID: approval.approvalID)
            } label: {
                Text("✕ Dismiss")
            }
            .buttonStyle(NotchButtonStyle(verticalPadding: Theme.Metrics.Control.compactVerticalPadding))
            .font(Theme.Text.caption)
            .help("Hide this notice. The prompt stays open in the agent.")
        }
    }

    /// What to press once there: the option numbers for a question, return for a permission.
    private var keyHint: String {
        guard let question, !question.options.isEmpty else { return "⏎ there to allow" }
        return question.options.count == 1 ? "press 1 there" : "press 1–\(question.options.count) there"
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

/// The card's one filled button, in the prompt's own colour, so the way to answer is the most
/// visible thing on it rather than the least.
private struct PromptPrimaryButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Text.caption)
            .foregroundStyle(Theme.Colors.surface)
            .lineLimit(1)
            .padding(.horizontal, Theme.Metrics.Control.horizontalPadding)
            .padding(.vertical, Theme.Metrics.Control.compactVerticalPadding + 1)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.Control.cornerRadius, style: .continuous)
                    .fill(tint.opacity(configuration.isPressed ? 0.8 : 1))
            )
            .contentShape(Rectangle())
    }
}
