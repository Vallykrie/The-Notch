import AppKit
import SwiftUI

/// Every preference the app has, on one screen.
///
/// There is no settings *window*. Opening one would mean an ordinary titled `NSWindow` with a
/// system toolbar and system controls in it, which is precisely the thing this app spends its
/// whole design budget not looking like — and it would activate the app over whatever the user
/// is working in, for a switch they came to flip in half a second. So settings are a surface
/// inside the same 640x190 silhouette as the other two.
///
/// That constraint decides the layout. Four short columns, one group each, and no scrolling:
/// a scroll view here would show four rows and a gutter, and `ImageRenderer` draws one as empty
/// so `FrameDump` could never verify this surface. If a tenth preference ever needs a home, the
/// answer is to retire one, not to add a scroll view.
///
/// The panel's actions — Restore Defaults and Quit — are deliberately *not* here. They live in
/// the panel header beside the gear, because a footer row does not fit under the tallest column
/// and pushing one in would have cost the grid every other surface is laid out on.
@MainActor
struct SettingsExpandedView: View {
    @ObservedObject var settings: NotchSettings
    @ObservedObject var mediaKeys: MediaKeyInterceptor

    @ObservedObject var integrations: AgentIntegrationManager
    @ObservedObject var store: AgentSessionStore
    var onReplayIntro: () -> Void = {}
    @State private var showingConnections = false

    var body: some View {
        Group {
            if showingConnections {
                AgentConnectionsView(integrations: integrations, store: store) { showingConnections = false }
            } else { settingsGrid }
        }
        .foregroundStyle(Theme.Colors.textPrimary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, Theme.Metrics.expandedHorizontalPadding)
        .padding(.bottom, Theme.Metrics.expandedVerticalPadding)
        .padding(.bottom, Theme.Metrics.expandedBottomContentInset)
    }

    private var settingsGrid: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.Settings.columnSpacing) {
            column("Media") {
                SettingsToggleRow(label: "Show media", isOn: $settings.showMediaActivity)
                SettingsToggleRow(label: "Hide when paused", isOn: $settings.hideMediaWhenPaused)
            }

            column("Agents") {
                SettingsToggleRow(label: "Show agents", isOn: $settings.showAgentActivity)
                SettingsToggleRow(label: "Attention ring", isOn: $settings.showAttentionRing)
                SettingsToggleRow(label: "Show model", isOn: $settings.showAgentModel)
                SettingsToggleRow(label: "Sound cues", isOn: $settings.soundCuesEnabled)
                // "Keep done", not "Keep finished". The value field beside it is wider than a
                // switch, so this row has ~14 characters to work in rather than ~18, and the
                // longer wording rendered as "Keep finis…".
                SettingsChoiceRow(label: "Keep done", selection: $settings.finishedRetention)
                Button("Connections…") { showingConnections = true }
                    .font(Theme.Text.micro).buttonStyle(.plain)
            }

            column("System") {
                SettingsToggleRow(label: "Replace OS HUD", isOn: $settings.replaceSystemHUD)
                SettingsChoiceRow(label: "HUD dwell", selection: $settings.hudDwell)
                Button(mediaKeys.status.rawValue) { mediaKeys.openPermissionSettings() }
                    .font(Theme.Text.micro)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .help(mediaKeys.status == .permissionLost
                        ? "macOS tied the permission to an earlier build of The Notch. Remove The Notch from the Accessibility list and add it again."
                        : "Accessibility permission lets The Notch replace the system brightness and volume indicators.")
            }

            column("Behaviour") {
                SettingsToggleRow(label: "Expand on hover", isOn: $settings.expandOnHover)
                SettingsChoiceRow(label: "Hover speed", selection: $settings.hoverSensitivity)
                SettingsToggleRow(label: "Launch at login", isOn: $settings.launchAtLogin)
                // "Celebrate", not "Celebrate finished runs": the row has ~14 characters.
                SettingsToggleRow(label: "Celebrate done", isOn: $settings.celebrateFinishedRuns)
                Button("Replay intro…", action: onReplayIntro)
                    .font(Theme.Text.micro)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .help("Play the first-launch intro again, including the question about hooking up your agents.")
                Button("Donate…") { NSWorkspace.shared.open(SupportLinks.donate) }
                    .font(Theme.Text.micro)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .help("The Notch is free and open source. Donations fund its development.")
            }
        }

    }

    /// Columns take an equal share of the panel rather than hugging their content, so the four
    /// switches line up in a single vertical run down the right of each column. Ragged control
    /// edges are what make a dense preference grid unreadable.
    private func column(
        _ title: String,
        @ViewBuilder _ rows: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.Settings.headerSpacing) {
            Text(title.uppercased())
                .font(Theme.Text.micro)
                .foregroundStyle(Theme.Colors.textTertiary)

            VStack(alignment: .leading, spacing: Theme.Metrics.Settings.rowSpacing) {
                rows()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Rows

/// A label and a switch, where the *row* is the button.
///
/// A 20x11pt switch is a 20x11pt click target otherwise, at the top edge of the screen, against
/// a cursor that is already fighting the menu bar. The same reasoning as the media transport's
/// oversized hit targets, and the same fix.
@MainActor
private struct SettingsToggleRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: Theme.Metrics.Settings.labelSpacing) {
                Text(label)
                    .font(Theme.Text.caption)
                    .foregroundStyle(
                        isOn ? Theme.Colors.textPrimary : Theme.Colors.textSecondary
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: .zero)

                SettingsSwitch(isOn: isOn)
            }
            .frame(height: Theme.Metrics.Settings.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// A label and a value that cycles on click.
///
/// Not a `Picker`. A pop-up menu is an AppKit window, and an AppKit window opening out of a
/// `.statusBar`-level panel that collapses when the pointer leaves it is a fight nobody wins:
/// the menu takes the pointer, the notch collapses out from under it, and the user is left with
/// a menu floating over the desktop attached to nothing. Every choice here has three or four
/// values, so cycling costs at most three clicks and never leaves the panel.
@MainActor
private struct SettingsChoiceRow<Option: SettingsOption>: View {
    let label: String
    @Binding var selection: Option

    var body: some View {
        Button {
            withAnimation(Theme.Motion.content) {
                selection = selection.next
            }
        } label: {
            HStack(spacing: Theme.Metrics.Settings.labelSpacing) {
                Text(label)
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: .zero)

                Text(selection.label)
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, Theme.Metrics.Settings.choiceHorizontalPadding)
                    // Shorter than the row, so the field reads as a control sitting on the row
                    // rather than as the row itself being tinted. Two modifiers because there
                    // is no `frame(minWidth:height:)` overload — the fixed height has to be
                    // applied before the flexible width, or the minimum is lost.
                    .frame(height: Theme.Metrics.Settings.rowHeight - 4)
                    .frame(minWidth: Theme.Metrics.Settings.choiceMinWidth)
                    .background(
                        RoundedRectangle(
                            cornerRadius: Theme.Metrics.Settings.choiceCornerRadius,
                            style: .continuous
                        )
                        .fill(
                            Theme.Colors.textPrimary
                                .opacity(Theme.Metrics.Settings.choiceFillOpacity)
                        )
                    )
                    .contentTransition(.identity)
            }
            .frame(height: Theme.Metrics.Settings.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(selection.label)
        .accessibilityHint("Cycles through the available values")
    }
}

/// The switch itself. Drawn rather than borrowed: `Toggle` renders AppKit's system switch, which
/// is tinted with the user's accent colour and is the single most recognisable "this is a
/// standard settings sheet" mark there is.
@MainActor
private struct SettingsSwitch: View {
    let isOn: Bool

    private var knobSide: CGFloat {
        Theme.Metrics.Settings.switchHeight - Theme.Metrics.Settings.switchKnobInset * 2
    }

    var body: some View {
        Capsule(style: .continuous)
            .fill(
                Theme.Colors.textPrimary.opacity(
                    isOn
                        ? Theme.Metrics.Settings.switchOnFillOpacity
                        : Theme.Metrics.Settings.switchOffFillOpacity
                )
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        Theme.Colors.textPrimary
                            .opacity(Theme.Metrics.Settings.switchBorderOpacity),
                        lineWidth: Theme.Metrics.Control.borderWidth
                    )
            )
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(isOn ? Theme.Colors.surface : Theme.Colors.textSecondary)
                    .frame(width: knobSide, height: knobSide)
                    .padding(Theme.Metrics.Settings.switchKnobInset)
            }
            .frame(
                width: Theme.Metrics.Settings.switchWidth,
                height: Theme.Metrics.Settings.switchHeight
            )
            .animation(Theme.Motion.content, value: isOn)
    }
}

// MARK: - Options

/// What a cycling choice row needs from its enum. The three option enums in `NotchSettings`
/// conform; nothing else should, because `next` wrapping past the end is only sensible for a set
/// small enough to click through.
protocol SettingsOption: CaseIterable, Identifiable, Equatable {
    var label: String { get }
}

extension SettingsOption {
    var next: Self {
        let all = Array(Self.allCases)
        guard let index = all.firstIndex(of: self) else { return self }
        return all[(index + 1) % all.count]
    }
}

extension FinishedRetention: SettingsOption {}
extension HUDDwell: SettingsOption {}
extension HoverSensitivity: SettingsOption {}
