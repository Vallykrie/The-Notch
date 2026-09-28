import SwiftUI

@MainActor
struct AgentsExpandedView: View {
    @ObservedObject var store: AgentSessionStore
    let namespace: Namespace.ID
    /// Where the pointer is over the panel, so each mascot can look at it.
    @State private var pointer = MascotPointer()

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

    /// Scrolls only when the rows genuinely overflow the panel.
    ///
    /// An unconditional `ScrollView` cost us twice: it put a scroll gutter next to two rows,
    /// and `ImageRenderer` draws a `ScrollView` as empty, so `FrameDump` could never verify
    /// this surface. `ViewThatFits` takes the plain stack whenever it fits, which is the common
    /// case and the one the dump exercises.
    private var sessionList: some View {
        ViewThatFits(in: .vertical) {
            rows
            ScrollView {
                rows
            }
            .scrollIndicators(.hidden)
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
                    // Withheld rather than disabled while an approval is blocking. A greyed-out
                    // control invites the user to keep clicking it; no control at all says the
                    // row is not going anywhere until the approval is answered, which is true.
                    onHide: store.canHide(sessionID: session.id)
                        ? { hide(session) }
                        : nil
                )
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
        HStack(spacing: Theme.Metrics.expandedContentSpacing) {
            PixelGlyphView(glyph: .chip, side: Theme.Metrics.glyphExpandedSize)
                .foregroundStyle(Theme.Colors.textTertiary)

            Text("Agent sessions appear here when a coding agent starts working.")
                .font(Theme.Text.body)
                .foregroundStyle(Theme.Colors.textSecondary)

            Spacer(minLength: .zero)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
