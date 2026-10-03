import AppKit
import SwiftUI

/// What the agents panel shows when nothing is running — the "sleeping crew".
///
/// ```
///  [ big blob,   ]  All quiet
///  [ asleep, zZ  ]  Sessions show up the moment an agent starts working.
///                   (Claude ●) (Codex ●) (Gemini ○) (Cursor ○)
///                   2 not connected · Set up hooks →
/// ```
///
/// It used to be a grey 8x8 chip beside one sentence, which made the tab look broken rather
/// than quiet. The mascot goes in instead, at panel scale, so `AgentActivityGlyph`'s breathing
/// and snoring carry the "nothing is happening, and that's fine" a sentence was failing to.
///
/// Each agent found on this Mac gets a chip whose dot is lit while that agent is actually
/// open — its app, or its CLI in some terminal — and clicking it brings that window forward,
/// or launches the app when it is not running. Hook health is the footer's job: most people
/// who see this screen see it because a hook is not installed, so it links straight to the
/// connections list rather than making them find it under Settings.
@MainActor
struct AgentsEmptyStateView: View {
    @ObservedObject var integrations: AgentIntegrationManager
    @ObservedObject var store: AgentSessionStore
    @State private var showingConnections = false
    @State private var presence: [AgentCLI: AgentPresence] = [:]

    var body: some View {
        Group {
            if showingConnections {
                AgentConnectionsView(
                    integrations: integrations,
                    store: store,
                    backTitle: "Agents"
                ) {
                    showingConnections = false
                }
            } else {
                crew
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await watchPresence() }
    }

    /// Re-scans for as long as the panel is on screen; SwiftUI cancels the task when it leaves.
    private func watchPresence() async {
        while !Task.isCancelled {
            let apps = NSWorkspace.shared.runningApplications.compactMap { app in
                app.bundleURL.map { AgentPresenceScanner.RunningApp(bundleURL: $0, processID: app.processIdentifier) }
            }
            let found = await Task.detached(priority: .utility) {
                AgentPresenceScanner().scan(runningApps: apps)
            }.value
            guard !Task.isCancelled else { return }
            // Animated, so a chip that comes online slides to the front instead of jumping.
            if found != presence {
                withAnimation(Theme.Motion.content) { presence = found }
            }
            try? await Task.sleep(for: .seconds(Theme.Metrics.Agents.presenceRefreshInterval))
        }
    }

    /// Brings the agent's window forward if it is open, otherwise launches its app. A CLI that is
    /// not running has nothing to open, so its chip does nothing.
    private func open(_ agent: AgentCLI) {
        guard let url = presence[agent]?.applicationURL ?? AgentPresenceScanner.installedApplicationURL(for: agent) else {
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    private var crew: some View {
        HStack(alignment: .center, spacing: Theme.Metrics.expandedContentSpacing) {
            // `.distantPast` puts it to sleep straight away: the glyph treats an idle mark
            // whose last activity is old enough as asleep, and nothing has happened.
            StatusIndicator(
                status: .idle,
                size: Theme.Metrics.Agents.emptyMascotSize,
                lastActivity: .distantPast
            )
            .frame(width: Theme.Metrics.Agents.emptyMascotColumnWidth)
            .frame(maxHeight: .infinity)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Theme.Metrics.Agents.emptyChipSpacing) {
                Text("All quiet")
                    .font(Theme.Text.title)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)

                Text(hint)
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if !detected.isEmpty {
                    EmptyChipFlow(spacing: Theme.Metrics.Agents.emptyChipSpacing) {
                        ForEach(chipOrder) { status in
                            ProviderChip(
                                status: status,
                                isRunning: presence[status.provider] != nil,
                                canOpen: presence[status.provider]?.applicationURL != nil
                                    || AgentPresenceScanner.installedApplicationURL(for: status.provider) != nil
                            ) {
                                open(status.provider)
                            }
                        }
                    }
                    .padding(.top, 2)
                }

                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        // `statuses` is empty until the first detection pass lands; say nothing until then
        // rather than claiming "nothing installed" for a quarter of a second.
        if !integrations.statuses.isEmpty {
            HStack(spacing: 4) {
                if detected.isEmpty {
                    Text("No supported agent found")
                        .foregroundStyle(Theme.Colors.textTertiary)
                    Text("·").foregroundStyle(Theme.Colors.textTertiary)
                    setUpLink
                } else if disconnectedCount == 0 {
                    Text("Listening on all \(detected.count) agent\(detected.count == 1 ? "" : "s")")
                        .foregroundStyle(Theme.Colors.textTertiary)
                } else {
                    Text("\(disconnectedCount) not connected")
                        .foregroundStyle(Theme.Colors.textTertiary)
                    Text("·").foregroundStyle(Theme.Colors.textTertiary)
                    setUpLink
                }
            }
            .font(Theme.Text.micro)
            .lineLimit(1)
            .padding(.top, 2)
        }
    }

    private var setUpLink: some View {
        Button {
            withAnimation(Theme.Motion.content) { showingConnections = true }
        } label: {
            Text("Set up hooks →")
                .underline()
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .buttonStyle(.plain)
        .help("Show which agents The Notch is hooked into")
    }

    // MARK: Derived

    /// Only the agents actually installed. A chip for every CLI the app knows about would turn
    /// a quiet panel into a shopping list.
    /// Open agents first, then the rest, each group keeping the registry's order — so the chips
    /// a user can click are always the first ones they read, and nothing reshuffles otherwise.
    private var chipOrder: [AgentIntegrationStatus] {
        let open = detected.filter { presence[$0.provider] != nil }
        let closed = detected.filter { presence[$0.provider] == nil }
        return open + closed
    }

    private var detected: [AgentIntegrationStatus] {
        integrations.statuses.filter(\.installed)
    }

    private var disconnectedCount: Int {
        detected.filter { !$0.configured }.count
    }

    private var hint: String {
        if !integrations.statuses.isEmpty, detected.isEmpty {
            return "Install a coding agent and its sessions show up here."
        }
        return "Sessions show up the moment an agent starts working."
    }
}

// MARK: - Chip

/// One detected agent: its short name and a dot that is lit while it is open. Clicking it
/// brings the agent forward.
@MainActor
private struct ProviderChip: View {
    let status: AgentIntegrationStatus
    let isRunning: Bool
    let canOpen: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) { label }
            .buttonStyle(.plain)
            .disabled(!canOpen)
            .onHover { isHovered = $0 && canOpen }
            .help(helpText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(status.provider.displayName): \(accessibilityState)")
            .accessibilityAddTraits(.isButton)
    }

    private var label: some View {
        HStack(spacing: 6) {
            Text(shortName)
                .font(Theme.Text.micro)
                .foregroundStyle(isRunning ? Theme.Colors.textPrimary : Theme.Colors.textTertiary)
                .lineLimit(1)

            Circle()
                .fill(dotColor)
                .frame(
                    width: Theme.Metrics.Agents.emptyChipDotSize,
                    height: Theme.Metrics.Agents.emptyChipDotSize
                )
        }
        .padding(.horizontal, Theme.Metrics.Agents.emptyChipHorizontalPadding)
        .padding(.vertical, Theme.Metrics.Agents.emptyChipVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.Agents.emptyChipCornerRadius, style: .continuous)
                .fill(Color.white.opacity(isHovered ? 0.14 : isRunning ? 0.08 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.Agents.emptyChipCornerRadius, style: .continuous)
                .strokeBorder(Theme.Colors.divider, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Metrics.Agents.emptyChipCornerRadius, style: .continuous))
        .animation(Theme.Motion.content, value: isHovered)
    }

    private var helpText: String {
        if let error = status.error { return error }
        if isRunning { return "Open \(status.provider.displayName)" }
        return canOpen ? "Launch \(status.provider.displayName)" : "\(status.provider.displayName) is not running"
    }

    /// The chips have to share a ~400pt column, so "Claude Code" and "Gemini CLI" lose the
    /// suffix every agent has.
    private var shortName: String {
        switch status.provider {
        case .claude: "Claude"
        case .gemini: "Gemini"
        default: status.provider.displayName
        }
    }

    private var dotColor: Color {
        if status.error != nil { return Theme.Colors.Status.needsApproval }
        return isRunning ? Theme.Colors.Status.done : Theme.Colors.textTertiary.opacity(0.6)
    }

    private var accessibilityState: String {
        if status.error != nil { return "setup needs attention" }
        return isRunning ? "running" : "not running"
    }
}

// MARK: - Flow layout

/// Left-to-right, wrapping to a new line when the next chip would not fit.
private struct EmptyChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
