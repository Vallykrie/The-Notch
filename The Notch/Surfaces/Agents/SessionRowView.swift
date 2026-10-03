import SwiftUI

@MainActor
struct SessionRowView: View {
    let session: AgentSession
    let namespace: Namespace.ID
    /// The subagents this session has spawned, drawn underneath it. Empty for a subagent's own
    /// row — subagents do not nest in any CLI we support, and a row that could indent forever
    /// would have to earn that with a real case.
    var children: [AgentSession] = []
    /// Whether the title line names the model as well as the app — see
    /// `NotchSettings.showAgentModel`.
    var showsModel = false
    /// One line instead of two — see `AgentsExpandedView.rows` for when a row is compact.
    var isCompact = false
    /// Removes this row from the panel. `nil` when the session is blocking on an approval —
    /// see `AgentSessionStore.canHide(sessionID:)` for why that one case must not be hideable.
    var onHide: (() -> Void)?

    @State private var isHovered = false

    /// A session reads as two lines of terminal transcript rather than as a list cell: the
    /// project on top, and what the agent is doing right now on a dim continuation line under
    /// it. That shape is why the panel scans like a log instead of like a settings pane.
    var body: some View {
        VStack(alignment: .leading, spacing: .zero) {
            if isCompact {
                compactLine
            } else {
                sessionLine
                subagentLines
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The whole row on one line: a smaller mascot in the same gutter, the project, what it is
    /// doing and where, and a short age. The text starts at the same x as a full row's, so a
    /// list mixing both still reads as one column.
    private var compactLine: some View {
        HStack(spacing: Theme.Metrics.expandedContentSpacing) {
            StatusIndicator(
                status: session.status,
                size: Theme.Metrics.Agents.compactGlyphSize,
                identity: session.id,
                lastActivity: session.lastActivity
            )
            .frame(width: Theme.Metrics.Agents.rowIconWidth, alignment: .leading)
            .matchedGeometryEffect(
                id: AgentSurfaceElement.status(sessionID: session.id),
                in: namespace
            )
            .accessibilityLabel("\(session.kind.displayName): \(session.status.label)")

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.displayName)
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)

                Text(compactSummary)
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: Theme.Metrics.collapsedContentSpacing)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(ApprovalCardView.elapsedLabel(context.date.timeIntervalSince(session.lastActivity)))
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
            }

            openControl
            hideControl
        }
        .frame(height: Theme.Metrics.Agents.compactRowHeight)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
    }

    /// `Waiting for input · Terminal`: the continuation line and the title's details, folded
    /// into the one line a compact row has.
    private var compactSummary: String {
        [continuationText, details].compactMap { $0 }.joined(separator: " · ")
    }

    private var sessionLine: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.expandedContentSpacing) {
            // One mark, not two. This row used to open with the agent's own sprite — a Claude
            // burst, a Codex chevron — and then the status mark immediately beside it, which
            // read as two icons competing for the same job. It was also the wrong pair to
            // spend the row's opening on: which agent it is does not change while you look at
            // the row, and the row already says so in the project line and the accessibility
            // label. What changes is what the agent is doing, so that is what gets the space.
            StatusIndicator(
                status: session.status,
                size: Theme.Metrics.Agents.activityGlyphSize,
                identity: session.id,
                lastActivity: session.lastActivity
            )
            .frame(width: Theme.Metrics.Agents.rowIconWidth, alignment: .leading)
            .matchedGeometryEffect(
                id: AgentSurfaceElement.status(sessionID: session.id),
                in: namespace
            )
            // The agent's identity has nowhere else to go now that its sprite is gone, and it
            // is the one part of this row a sighted user gets from the mascot's hue and a
            // VoiceOver user cannot get at all.
            .accessibilityLabel("\(session.kind.displayName): \(session.status.label)")
            // No top padding, deliberately. The dot this replaced was an 8pt mark beside 13pt
            // type and needed 3pt to sit on the baseline rather than floating at the cap line.
            // The mascot is 24pt and spans both lines of the row, so it aligns to the block
            // rather than to a baseline; 3pt would only push it out of the top of the row.

            VStack(alignment: .leading, spacing: 2) {
                titleLine
                continuationLine
            }

            Spacer(minLength: Theme.Metrics.collapsedContentSpacing)

            VStack(alignment: .trailing, spacing: 2) {
                Text(session.lastActivity, style: .relative)
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)

                if let usageSummary {
                    Text(usageSummary)
                        .font(Theme.Text.body)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .lineLimit(1)
                }
            }

            openControl
            hideControl
        }
        .padding(.vertical, Theme.Metrics.Agents.rowVerticalPadding)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        // `.contain`, not `.combine`. Combining flattened the row into one static element, which
        // was right while it held only text and is wrong now that it holds a button: a combined
        // element has no children, so the hide control would be unreachable to VoiceOver.
        .accessibilityElement(children: .contain)
    }

    /// A session's subagents, indented under it.
    ///
    /// They used to be sessions. A `Task` subagent's hook events carry the parent's session id
    /// with an `agent_id` of their own, so every one of them landed on the parent's row and
    /// fought over its status and its current tool — the panel showed a machine running five
    /// agents when it was running one that had delegated four times. A subagent is not another
    /// agent: it has no prompt of its own, it cannot outlive the thing that spawned it, and
    /// nobody counts it when they say how many agents they have going. So it is drawn as part
    /// of its parent's row, at a size that says so.
    ///
    /// Past `visibleSubagents` they become a count. A swarm is a number, not a list.
    @ViewBuilder
    private var subagentLines: some View {
        if !children.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(children.prefix(Theme.Metrics.Agents.visibleSubagents)) { child in
                    subagentLine(child)
                }

                if children.count > Theme.Metrics.Agents.visibleSubagents {
                    Text("+\(children.count - Theme.Metrics.Agents.visibleSubagents) more")
                        .font(Theme.Text.body)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .padding(.leading, Theme.Metrics.Agents.subagentIndent)
                }
            }
            .padding(.bottom, Theme.Metrics.Agents.rowVerticalPadding)
        }
    }

    private func subagentLine(_ child: AgentSession) -> some View {
        HStack(spacing: Theme.Metrics.collapsedContentSpacing) {
            StatusIndicator(
                status: child.status,
                size: Theme.Metrics.Agents.subagentGlyphSize,
                identity: child.id
            )

            Text(child.displayName)
                .font(Theme.Text.body)
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(1)

            // The parent row's own continuation mark, so a subagent line reads as a smaller
            // copy of a session line. Without it "Explore Grep" read as one name.
            HStack(spacing: 4) {
                Text("└")
                    .foregroundStyle(Theme.Colors.textTertiary)
                Text(nonEmpty(child.currentTool) ?? child.status.label)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(Theme.Text.body)

            Spacer(minLength: Theme.Metrics.collapsedContentSpacing)

            if let usage = Self.usageSummary(for: child) {
                Text(usage)
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, Theme.Metrics.Agents.subagentIndent)
        // Both trailing controls' slots, so a subagent's usage lines up with its parent's.
        .padding(.trailing, Theme.Metrics.Settings.dismissHitSize * 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Subagent \(child.displayName): \(child.status.label)")
    }

    /// Takes a finished or idle session out of the panel.
    ///
    /// The slot is reserved even when there is nothing to put in it. A control that appears on
    /// hover and *also* takes up space when it appears reflows the row under the pointer, which
    /// moves the timestamp and the usage figures sideways every time the cursor crosses a row —
    /// so the space is always there and only the ink comes and goes.
    ///
    /// It is dim at rest rather than absent because a control that is completely invisible until
    /// hovered is a control nobody knows exists.
    @ViewBuilder
    private var hideControl: some View {
        if let onHide {
            Button(action: onHide) {
                PixelGlyphView(
                    glyph: .minus,
                    side: Theme.Metrics.Settings.dismissGlyphSize
                )
                .foregroundStyle(Theme.Colors.textPrimary)
                .opacity(isHovered ? 1 : Theme.Metrics.Settings.dismissRestingOpacity)
                .frame(
                    width: Theme.Metrics.Settings.dismissHitSize,
                    height: Theme.Metrics.Settings.dismissHitSize
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(Theme.Motion.content, value: isHovered)
            .accessibilityLabel("Hide \(session.displayName)")
        } else {
            Color.clear
                .frame(
                    width: Theme.Metrics.Settings.dismissHitSize,
                    height: Theme.Metrics.Settings.dismissHitSize
                )
        }
    }

    /// The project, then what tells two sessions in the same project apart: the model answering
    /// and the app it runs in — `my-app  Opus 4.5 · Terminal`. The project keeps its width and
    /// the details give way, because the project is what the row is *about*.
    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(session.displayName)
                .font(Theme.Text.title)
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            if let details {
                Text(details)
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    /// The model (when the setting asks for it and it is known), then the host app. Whatever
    /// is missing, the agent's own name stands in, so the line is never blank.
    private var details: String? {
        var parts: [String] = []
        if showsModel, let model = nonEmpty(session.model) {
            parts.append(ModelName.display(model))
        } else if session.host == nil {
            parts.append(session.kind.displayName)
        }
        // An agent running in its own app would read `Antigravity · Antigravity`.
        if let host = session.host, !parts.contains(host.name) { parts.append(host.name) }
        return parts.joined(separator: " · ")
    }

    /// Brings the session's terminal tab, IDE window or app forward. Same resting treatment
    /// and reserved slot as the hide control beside it, for the same reasons.
    @ViewBuilder
    private var openControl: some View {
        if SessionWindowOpener.canOpen(session) {
            Button {
                SessionWindowOpener.open(session)
            } label: {
                PixelGlyphView(
                    glyph: .openWindow,
                    side: Theme.Metrics.Settings.dismissGlyphSize
                )
                .foregroundStyle(Theme.Colors.textPrimary)
                .opacity(isHovered ? 1 : Theme.Metrics.Settings.dismissRestingOpacity)
                .frame(
                    width: Theme.Metrics.Settings.dismissHitSize,
                    height: Theme.Metrics.Settings.dismissHitSize
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(Theme.Motion.content, value: isHovered)
            .help(session.host.map { "Open in \($0.name)" } ?? "Open \(session.kind.displayName)")
            .accessibilityLabel("Open \(session.displayName)")
        } else {
            Color.clear
                .frame(
                    width: Theme.Metrics.Settings.dismissHitSize,
                    height: Theme.Metrics.Settings.dismissHitSize
                )
        }
    }

    /// `└ Edit(src/theme.css)` when a tool is live, otherwise the plain state.
    private var continuationLine: some View {
        HStack(spacing: 4) {
            Text("└")
                .font(Theme.Text.body)
                .foregroundStyle(Theme.Colors.textTertiary)

            Text(continuationText)
                .font(Theme.Text.body)
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// What the session is doing, plus — when it has delegated — how many helpers are hanging
    /// under it, which is what explains the indented lines below.
    private var continuationText: String {
        let doing = nonEmpty(session.currentTool) ?? session.status.label
        guard !children.isEmpty else { return doing }
        return "\(doing) · \(children.count) subagent\(children.count == 1 ? "" : "s")"
    }

    private var usageSummary: String? { Self.usageSummary(for: session) }

    /// What the session has spent, in the two numbers that mean something at a glance.
    ///
    /// This column was empty on every row until now, and the reason was upstream of the
    /// formatting: hook payloads carry no usage at all, so there was never anything to format.
    /// The numbers now come from the agent's own transcript — see `TranscriptUsageReader`.
    ///
    /// Context first, because it is the one that fills up and the one a person acts on. Output
    /// second, because it is what the session has actually produced. A cumulative *total* is
    /// deliberately not shown: with prompt caching it grows by the whole context every turn,
    /// so it reads like a runaway bill for work that cost a fraction of it. Cost appears only
    /// when the agent states one; we do not multiply by a price table that goes stale the day
    /// a model ships.
    static func usageSummary(for session: AgentSession) -> String? {
        var components: [String] = []
        if let context = session.contextTokens, context > 0 {
            components.append(context.formatted(.number.notation(.compactName)) + " ctx")
        }
        if let output = session.outputTokens, output > 0 {
            components.append(output.formatted(.number.notation(.compactName)) + " out")
        }
        if components.isEmpty, let tokens = session.totalTokens, tokens > 0 {
            components.append(tokens.formatted(.number.notation(.compactName)) + " tok")
        }
        if let cost = session.costUSD, cost > 0 {
            components.append(
                cost.formatted(.currency(code: "USD").precision(.fractionLength(2)))
            )
        }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
