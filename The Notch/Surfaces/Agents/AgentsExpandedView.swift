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
    /// Where each row sits inside the scrolling list, for counting the rows below the fold.
    @State private var rowFrames: [String: CGRect] = [:]

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

    /// Every session as a full two-line row. When they fit, a plain stack; when they do not,
    /// a scroll view that says so.
    ///
    /// The plain stack comes first because `ImageRenderer` draws a `ScrollView` as empty, so
    /// it is the only form `FrameDump` can verify, and because a scroll view around two rows
    /// is a gutter for nothing.
    private var sessionList: some View {
        ViewThatFits(in: .vertical) {
            rows
            scrollingRows
        }
    }

    /// The overflow case. A bare scroll view cut its last row through the middle at the
    /// bottom curve, which read as a rendering bug rather than as "there is more". So the list
    /// fades out over its last few points, and a pill says how many rows are below the fold
    /// and scrolls the next one into view.
    private var scrollingRows: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    rows
                }
                .scrollIndicators(.hidden)
                .coordinateSpace(name: Self.scrollSpace)
                .onPreferenceChange(RowFramesKey.self) { rowFrames = $0 }
                .mask(alignment: .bottom) {
                    VStack(spacing: 0) {
                        Color.black
                        if !hiddenSessions(below: viewport.size.height).isEmpty {
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: Theme.Metrics.Agents.scrollFadeHeight)
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    moreBelowHint(hiddenSessions(below: viewport.size.height), proxy: proxy)
                }
            }
        }
    }

    private static let scrollSpace = "agents-scroll"

    /// Sessions whose row ends below the visible part of the list, in list order.
    private func hiddenSessions(below visibleHeight: CGFloat) -> [AgentSession] {
        store.sessions.filter { session in
            guard let frame = rowFrames[session.id] else { return false }
            return frame.maxY > visibleHeight + 1
        }
    }

    @ViewBuilder
    private func moreBelowHint(_ hidden: [AgentSession], proxy: ScrollViewProxy) -> some View {
        if let next = hidden.first {
            Button {
                withAnimation(Theme.Motion.content) {
                    proxy.scrollTo(next.id, anchor: .bottom)
                }
            } label: {
                HStack(spacing: 4) {
                    Text("↓")
                    Text("\(hidden.count) more")
                }
                .font(Theme.Text.micro)
                .foregroundStyle(Theme.Colors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule(style: .continuous).fill(Theme.Colors.surface))
                .overlay(Capsule(style: .continuous).strokeBorder(Theme.Colors.divider, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.bottom, Theme.Metrics.Agents.scrollHintInset)
            .transition(.opacity)
            .help("Scroll to see more sessions")
            .accessibilityLabel("\(hidden.count) more sessions below")
        }
    }

    /// Not a `LazyVStack`: the panel only ever holds a handful of rows, so laziness buys
    /// nothing and costs offscreen rendering.
    private var rows: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.collapsedContentSpacing) {
            ForEach(store.sessions) { session in
                SessionRowView(
                    session: session,
                    namespace: namespace,
                    children: store.children(of: session.id),
                    showsModel: showsModel,
                    // Withheld rather than disabled while an approval is blocking. A greyed-out
                    // control invites the user to keep clicking it; no control at all says the
                    // row is not going anywhere until the approval is answered, which is true.
                    onHide: store.canHide(sessionID: session.id)
                        ? { hide(session) }
                        : nil
                )
                .id(session.id)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: RowFramesKey.self,
                            value: [session.id: geometry.frame(in: .named(Self.scrollSpace))]
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// Each session row's frame in the scrolling list, keyed by session id.
private struct RowFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
