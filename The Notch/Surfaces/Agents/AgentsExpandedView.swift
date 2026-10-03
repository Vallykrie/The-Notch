import SwiftUI

@MainActor
struct AgentsExpandedView: View {
    @ObservedObject var store: AgentSessionStore
    /// Only read by the empty state, to say which agents on this Mac are hooked up.
    @ObservedObject var integrations: AgentIntegrationManager
    let namespace: Namespace.ID
    /// `NotchSettings.showAgentModel`, passed down so the rows do not each observe settings.
    var showsModel = false
    /// Where the pointer is over the panel, so each mascot can look at it.
    @State private var pointer = MascotPointer()
    /// The compact row the user clicked open, if any. One at a time: opening a second closes
    /// the first, so the list never grows past what the panel holds.
    @State private var expandedSessionID: String?
    /// Set by the `+N more` line: the whole list, in a scroll view. Cleared when the panel
    /// closes, so the next opening starts from the fitted list again.
    @State private var showsAllSessions = false

    var body: some View {
        Group {
            if let approval = oldestApproval {
                ApprovalCardView(
                    store: store,
                    approval: approval,
                    namespace: namespace
                )
            } else if store.sessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
        .foregroundStyle(Theme.Colors.textPrimary)
        // The shell owns the gap below the header. Keep only bottom clearance here,
        // with a smaller inset for questions that need room for answer options.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, Theme.Metrics.expandedHorizontalPadding)
        .padding(.bottom, verticalInset)
        .padding(.bottom, Theme.Metrics.expandedBottomContentInset)
        .environment(pointer)
        .onDisappear {
            showsAllSessions = false
            expandedSessionID = nil
        }
        .onContinuousHover(coordinateSpace: .global) { phase in
            switch phase {
            case let .active(location): pointer.location = location
            case .ended: pointer.location = nil
            }
        }
    }

    private var verticalInset: CGFloat {
        oldestApproval?.question == nil
            ? Theme.Metrics.expandedVerticalPadding
            : Theme.Metrics.Agents.questionVerticalPadding
    }

    private var oldestApproval: PendingApproval? {
        store.pendingApprovals.min { $0.requestedAt < $1.requestedAt }
    }

    /// The rows, as many as fit, with a `+N more` line for the rest.
    ///
    /// `ViewThatFits` is handed one candidate per visible count, largest first, and keeps the
    /// first that fits — so the panel shows every row it has room for and never one cut through
    /// by the bottom curve, which is what three full rows used to do. The plain stacks are also
    /// what `FrameDump` can render; `ImageRenderer` draws a `ScrollView` as empty, so the scroll
    /// view only exists once the user asks for the whole list.
    @ViewBuilder
    private var sessionList: some View {
        let sessions = store.sessions
        if showsAllSessions {
            ScrollView { rows(sessions, limit: sessions.count) }
                .scrollIndicators(.hidden)
        } else {
            ViewThatFits(in: .vertical) {
                ForEach(Array(stride(from: sessions.count, through: 1, by: -1)), id: \.self) { limit in
                    rows(sessions, limit: limit)
                }
            }
        }
    }

    /// Not a `LazyVStack`: the panel only ever holds a handful of rows, so laziness buys
    /// nothing and costs offscreen rendering.
    private func rows(_ sessions: [AgentSession], limit: Int) -> some View {
        let compactsOthers = sessions.count >= Theme.Metrics.Agents.compactThreshold
        return VStack(alignment: .leading, spacing: compactsOthers ? 2 : Theme.Metrics.collapsedContentSpacing) {
            ForEach(Array(sessions.prefix(limit).enumerated()), id: \.element.id) { index, session in
                let isCompact = compactsOthers && !isFullRow(session, at: index)
                SessionRowView(
                    session: session,
                    namespace: namespace,
                    children: store.children(of: session.id),
                    showsModel: showsModel,
                    isCompact: isCompact,
                    // Withheld rather than disabled while an approval is blocking. A greyed-out
                    // control invites the user to keep clicking it; no control at all says the
                    // row is not going anywhere until the approval is answered, which is true.
                    onHide: store.canHide(sessionID: session.id)
                        ? { hide(session) }
                        : nil
                )
                // A compact row opens into a full one on click, and a row opened that way
                // closes again the same way. The row's own buttons are `Button`s, so they keep
                // their clicks; the gesture only gets the rest of the row.
                .contentShape(Rectangle())
                .onTapGesture {
                    guard compactsOthers, index != 0 else { return }
                    withAnimation(Theme.Motion.content) {
                        expandedSessionID = expandedSessionID == session.id ? nil : session.id
                    }
                }
            }

            if limit < sessions.count {
                Button {
                    withAnimation(Theme.Motion.content) { showsAllSessions = true }
                } label: {
                    Text("+\(sessions.count - limit) more")
                        .font(Theme.Text.body)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .padding(.leading, Theme.Metrics.Agents.subagentIndent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Which rows keep both lines once the list goes compact: the session the user last spoke
    /// to (the list's first), one the user clicked open, and any that is waiting on the user —
    /// an approval or a question is never folded into a line it might not fit on.
    private func isFullRow(_ session: AgentSession, at index: Int) -> Bool {
        index == 0 || session.id == expandedSessionID || session.status.demandsAttention
    }

    /// Animated here rather than inside the row: the row is what disappears, so it cannot own
    /// the transaction that removes it. `Motion.content` and not `Motion.resize` — the panel is
    /// a fixed size and only the list beneath the removed row moves.
    private func hide(_ session: AgentSession) {
        withAnimation(Theme.Motion.content) {
            _ = store.hideSession(id: session.id)
        }
    }

    private var emptyState: some View {
        AgentsEmptyStateView(integrations: integrations, store: store)
    }
}
