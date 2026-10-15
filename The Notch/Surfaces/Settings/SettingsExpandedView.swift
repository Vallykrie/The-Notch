import AppKit
import SwiftUI

/// Every preference the app has, one feature at a time.
///
/// There is no settings *window*. Opening one would mean an ordinary titled `NSWindow` with a
/// system toolbar and system controls in it, which is precisely the thing this app spends its
/// whole design budget not looking like — and it would activate the app over whatever the user
/// is working in, for a switch they came to flip in half a second. So settings are a surface
/// inside the same 640x190 silhouette as the others.
///
/// It used to be one grid of four columns, which was full: a fifteenth preference had nowhere
/// to go. Now a rail down the leading edge picks a section — Media, Agents, Crypto, Calendar, Display, General —
/// and the section gets the rest of the panel as two columns. Each feature section is headed
/// by that feature's own on/off switch, because someone who installed The Notch for agents
/// alone should be able to make the other two disappear, not merely look quieter.
///
/// Still no scrolling: `ImageRenderer` draws a scroll view as empty, so `FrameDump` could never
/// verify a section that needed one. A section that outgrows two columns is a section to split.
///
/// The panel's actions — Restore defaults, Updates and Quit — live in the panel header, where
/// the tab bar would be. Restore defaults takes the leading edge the tabs vacate while settings
/// are open, so the trailing edge is not a crowd of four buttons.
@MainActor
struct SettingsExpandedView: View {
    @ObservedObject var settings: NotchSettings
    @ObservedObject var mediaKeys: MediaKeyInterceptor
    @ObservedObject var integrations: AgentIntegrationManager
    @ObservedObject var store: AgentSessionStore
    @ObservedObject var trading: TradingStore
    @ObservedObject var calendar: CalendarStore
    var onReplayIntro: () -> Void = {}
    /// Leaves settings for the crypto panel, where the watchlist is edited.
    var onEditWatchlist: () -> Void = {}

    @State private var section: SettingsSection
    /// Which side the incoming section slides in from: +1 from the trailing edge when moving
    /// down the rail, -1 from the leading edge when moving up it.
    @State private var direction: CGFloat = 1
    @State private var showingConnections = false
    @State private var showingCalendars = false
    @Namespace private var railNamespace

    init(
        settings: NotchSettings,
        mediaKeys: MediaKeyInterceptor,
        integrations: AgentIntegrationManager,
        store: AgentSessionStore,
        trading: TradingStore,
        calendar: CalendarStore,
        initialSection: SettingsSection = .media,
        onReplayIntro: @escaping () -> Void = {},
        onEditWatchlist: @escaping () -> Void = {}
    ) {
        self.settings = settings
        self.mediaKeys = mediaKeys
        self.integrations = integrations
        self.store = store
        self.trading = trading
        self.calendar = calendar
        self.onReplayIntro = onReplayIntro
        self.onEditWatchlist = onEditWatchlist
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        Group {
            if showingConnections {
                AgentConnectionsView(integrations: integrations, store: store) { showingConnections = false }
            } else if showingCalendars {
                CalendarSourcesView(store: calendar) { showingCalendars = false }
            } else {
                HStack(alignment: .top, spacing: Theme.Metrics.Settings.railContentSpacing) {
                    rail
                    sectionContent
                        .id(section)
                        .transition(
                            .asymmetric(
                                insertion: .offset(x: Theme.Motion.Settings.sectionTravel * direction)
                                    .combined(with: .opacity),
                                removal: .opacity
                            )
                        )
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .clipped()
            }
        }
        .foregroundStyle(Theme.Colors.textPrimary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, Theme.Metrics.expandedHorizontalPadding)
        .padding(.bottom, Theme.Metrics.expandedVerticalPadding)
        .padding(.bottom, Theme.Metrics.expandedBottomContentInset)
    }

    // MARK: Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.Settings.railItemSpacing) {
            ForEach(SettingsSection.allCases) { item in
                railItem(item)
            }
        }
        .frame(width: Theme.Metrics.Settings.railWidth, alignment: .topLeading)
    }

    private func railItem(_ item: SettingsSection) -> some View {
        let isSelected = item == section
        let isOff = item.feature.map { !settings.isEnabled($0) } ?? false

        return Button {
            guard item != section else { return }
            direction = item.index > section.index ? 1 : -1
            withAnimation(Theme.Motion.Settings.section) {
                section = item
            }
        } label: {
            HStack(spacing: Theme.Metrics.Settings.railIconSpacing) {
                PixelGlyphView(glyph: item.glyph, side: Theme.Metrics.Settings.railIconSize)
                    // A switched-off feature's mark tips over and fades, so the rail says which
                    // features are off before any section is opened.
                    .rotationEffect(.degrees(isOff ? Theme.Motion.Settings.deadIconTilt : 0))
                    .opacity(isOff ? Theme.Metrics.Settings.disabledRowOpacity * 2 : 1)
                Text(item.title)
                    .font(Theme.Text.caption)
                    .lineLimit(1)
                Spacer(minLength: .zero)
                if item.feature != nil {
                    statusDot(isOn: !isOff)
                }
            }
            .foregroundStyle(isSelected ? Theme.Colors.textPrimary : Theme.Colors.textTertiary)
            .padding(.horizontal, Theme.Metrics.TabBar.horizontalPadding)
            .frame(height: Theme.Metrics.Settings.railItemHeight)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: Theme.Metrics.TabBar.cornerRadius, style: .continuous)
                        .fill(Theme.Colors.textPrimary.opacity(Theme.Metrics.TabBar.selectedFillOpacity))
                        .matchedGeometryEffect(id: "rail", in: railNamespace)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Metrics.TabBar.cornerRadius, style: .continuous))
            .animation(Theme.Motion.Settings.power, value: isOff)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityValue(item.feature == nil ? "" : (isOff ? "Off" : "On"))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Filled when the feature is on, hollow when it is off.
    private func statusDot(isOn: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(isOn ? Theme.Metrics.Settings.statusOnColor : .clear)
            .overlay(
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .strokeBorder(
                        Theme.Colors.textPrimary.opacity(isOn ? 0 : Theme.Metrics.Settings.statusOffBorderOpacity),
                        lineWidth: Theme.Metrics.Control.borderWidth
                    )
            )
            .frame(width: Theme.Metrics.Settings.railStatusSize, height: Theme.Metrics.Settings.railStatusSize)
    }

    // MARK: Sections

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .media: mediaSection
        case .agents: agentsSection
        case .crypto: cryptoSection
        case .calendar: calendarSection
        case .display: displaySection
        case .general: generalSection
        }
    }

    private var mediaSection: some View {
        featureColumns(.media) {
            SettingsToggleRow(label: "Show on notch", isOn: $settings.showMediaActivity)
            SettingsToggleRow(label: "Hide when paused", isOn: $settings.hideMediaWhenPaused)
        } right: {
            SettingsToggleRow(label: "Lyrics on notch", isOn: $settings.lyricsOnNotch)
            SettingsChoiceRow(label: "Players", selection: $settings.mediaPlayers)
        }
    }

    private var agentsSection: some View {
        featureColumns(.agents) {
            SettingsToggleRow(label: "Show on notch", isOn: $settings.showAgentActivity)
            SettingsToggleRow(label: "Attention ring", isOn: $settings.showAttentionRing)
            SettingsToggleRow(label: "Show model", isOn: $settings.showAgentModel)
            SettingsToggleRow(label: "Sound cues", isOn: $settings.soundCuesEnabled)
        } right: {
            SettingsToggleRow(label: "Open on approval", isOn: $settings.openOnApproval)
            SettingsToggleRow(label: "Celebrate done", isOn: $settings.celebrateFinishedRuns)
            SettingsChoiceRow(label: "Keep done", selection: $settings.finishedRetention)
            SettingsLinkRow(label: "Connections…") { showingConnections = true }
        }
    }

    private var cryptoSection: some View {
        featureColumns(.trading) {
            SettingsToggleRow(
                label: "Pinned on notch",
                isOn: Binding(get: { trading.showInNotch }, set: { trading.setShowInNotch($0) })
            )
            .help("Shows the pinned pair's price on the notch. Pin a pair from the watchlist.")
        } right: {
            SettingsLinkRow(label: "Edit watchlist…", action: onEditWatchlist)
        }
    }

    private var calendarSection: some View {
        featureColumns(.calendar) {
            SettingsToggleRow(label: "All-day events", isOn: $settings.calendarShowsAllDay)
        } right: {
            SettingsLinkRow(label: calendar.access == .granted ? "Calendars…" : "Connect calendars…") {
                if calendar.access == .granted {
                    showingCalendars = true
                } else {
                    calendar.requestAccess()
                }
            }
            .help("Choose which calendars the notch shows.")
            SettingsLinkRow(label: "Add account…") { CalendarStore.openInternetAccounts() }
                .help("Google, Microsoft Exchange / Outlook and CalDAV accounts are added in System Settings › Internet Accounts. Turn on Calendars for the account and it appears here.")
        }
    }

    /// How the notch looks and moves: the panel's size and shadow, and its open/close motion.
    private var displaySection: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.Settings.sectionColumnSpacing) {
            column(header: "Panel") {
                SettingsChoiceRow(label: "Size", selection: $settings.panelSize)
                    .help("How big the open panel is. L is the panel as designed; M and S scale it down.")
                SettingsToggleRow(label: "Shadow", isOn: $settings.panelShadow)
            }
            column(header: "Motion") {
                SettingsToggleRow(label: "Animations", isOn: $settings.animationsEnabled)
                    .help("Off, the panel appears and disappears without motion, and the attention effects are skipped.")
                SettingsChoiceRow(label: "Speed", selection: $settings.animationSpeed)
                    .modifier(PoweredDown(isOff: !settings.animationsEnabled))
                    .help("How fast the panel opens and closes.")
            }
        }
    }

    private var generalSection: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.Settings.sectionColumnSpacing) {
            column(header: "System") {
                SettingsToggleRow(label: "Replace OS HUD", isOn: $settings.replaceSystemHUD)
                SettingsChoiceRow(label: "HUD dwell", selection: $settings.hudDwell)
                SettingsStatusRow(
                    label: "Media keys",
                    status: mediaKeys.status.rawValue,
                    needsAction: mediaKeys.status.needsAction
                ) { mediaKeys.openPermissionSettings() }
                    .help(mediaKeys.status == .permissionLost
                        ? "macOS tied the permission to an earlier build of The Notch. Remove The Notch from the Accessibility list and add it again."
                        : "Accessibility permission lets The Notch replace the system brightness and volume indicators.")
            }
            column(header: "Behaviour") {
                SettingsToggleRow(label: "Expand on hover", isOn: $settings.expandOnHover)
                SettingsChoiceRow(label: "Hover speed", selection: $settings.hoverSensitivity)
                SettingsToggleRow(label: "Launch at login", isOn: $settings.launchAtLogin)
                SettingsLinkRow(label: "Replay intro…", action: onReplayIntro)
                    .help("Play the first-launch intro again, including the question about hooking up your agents.")
                SettingsLinkRow(label: "Donate…") { NSWorkspace.shared.open(SupportLinks.donate) }
                    .help("The Notch is free and open source. Donations fund its development.")
            }
        }
    }

    /// A feature's section: its on/off switch heading the leading column, its settings in two
    /// columns beneath and beside it. Switched off, the settings stay visible but dim and inert
    /// — they are kept for when the feature comes back, and hiding them would make the section
    /// look empty rather than off.
    private func featureColumns(
        _ feature: NotchSurface,
        @ViewBuilder left: () -> some View,
        @ViewBuilder right: () -> some View
    ) -> some View {
        let isOn = settings.isEnabled(feature)
        let binding = Binding(
            get: { settings.isEnabled(feature) },
            set: { value in
                withAnimation(Theme.Motion.Settings.power) {
                    switch feature {
                    case .media: settings.mediaEnabled = value
                    case .agents: settings.agentsEnabled = value
                    case .trading: settings.cryptoEnabled = value
                    case .calendar: settings.calendarEnabled = value
                    }
                }
            }
        )

        return HStack(alignment: .top, spacing: Theme.Metrics.Settings.sectionColumnSpacing) {
            column {
                SettingsToggleRow(label: isOn ? "Enabled" : "Off", isOn: binding)
                    .padding(.horizontal, Theme.Metrics.Settings.masterHorizontalPadding)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Metrics.Settings.masterCornerRadius, style: .continuous)
                            .fill(Theme.Colors.textPrimary.opacity(Theme.Metrics.Settings.masterFillOpacity))
                    )
                    // Pulled back out by the padding it took, so the plate bleeds past the
                    // column instead of pushing the label and switch 6pt off it.
                    .padding(.horizontal, -Theme.Metrics.Settings.masterHorizontalPadding)
                    .help(isOn
                        ? "Switch \(feature.title) off: its tab and shoulder go, and nothing runs for it in the background."
                        : "Switch \(feature.title) back on. Its settings were kept.")
                left()
                    .modifier(PoweredDown(isOff: !isOn))
            }
            column {
                right()
                    .modifier(PoweredDown(isOff: !isOn))
            }
        }
    }

    private func column(
        header: String? = nil,
        @ViewBuilder _ rows: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.Settings.headerSpacing) {
            if let header {
                Text(header.uppercased())
                    .font(Theme.Text.micro)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            VStack(alignment: .leading, spacing: Theme.Metrics.Settings.rowSpacing) {
                rows()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Sections

/// The settings rail's entries. The three features map onto `NotchSurface`; General holds
/// everything that belongs to the notch itself rather than to one feature.
enum SettingsSection: String, CaseIterable, Identifiable {
    case media
    case agents
    case crypto
    case calendar
    case display
    case general

    init(surface: NotchSurface) {
        switch surface {
        case .media: self = .media
        case .agents: self = .agents
        case .trading: self = .crypto
        case .calendar: self = .calendar
        }
    }

    var id: String { rawValue }

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    var title: String {
        switch self {
        case .media: "Media"
        case .agents: "Agents"
        case .crypto: "Crypto"
        case .calendar: "Calendar"
        case .display: "Display"
        case .general: "General"
        }
    }

    var glyph: PixelGlyph {
        switch self {
        case .media: .musicNote
        case .agents: .chip
        case .crypto: .coin
        case .calendar: .calendar
        case .display: .openWindow
        case .general: .gear
        }
    }

    /// The feature this section switches, or `nil` for Display and General.
    var feature: NotchSurface? {
        switch self {
        case .media: .media
        case .agents: .agents
        case .crypto: .trading
        case .calendar: .calendar
        case .display, .general: nil
        }
    }
}

/// A switched-off feature's settings: dimmed and inert, but still there.
private struct PoweredDown: ViewModifier {
    let isOff: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isOff ? Theme.Metrics.Settings.disabledRowOpacity : 1)
            .disabled(isOff)
            .animation(Theme.Motion.Settings.power, value: isOff)
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
    /// Bumped each time the switch turns on, to fire its sparks.
    @State private var sparks = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            isOn.toggle()
            if isOn, !reduceMotion { sparks += 1 }
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

                SettingsSwitch(isOn: isOn, animated: !reduceMotion)
                    .overlay(alignment: .trailing) { SparkBurst(trigger: sparks) }
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

/// A row that does something rather than holding a value: Connections…, Replay intro…
@MainActor
private struct SettingsLinkRow: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Theme.Text.micro)
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(1)
                .frame(height: Theme.Metrics.Settings.rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A labelled status with the action that changes it: "Media keys … Enable Accessibility".
///
/// The status used to be the whole row, so the healthy state was a bare "Off" under HUD
/// dwell with nothing saying what was off.
@MainActor
private struct SettingsStatusRow: View {
    let label: String
    let status: String
    let needsAction: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Metrics.Settings.labelSpacing) {
                Text(label)
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: .zero)

                Text(status)
                    .font(Theme.Text.micro)
                    .foregroundStyle(needsAction ? Theme.Colors.textPrimary : Theme.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(height: Theme.Metrics.Settings.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(status)
    }
}

/// A label and a value that cycles on click.
///
/// Not a `Picker`. A pop-up menu is an AppKit window, and an AppKit window opening out of a
/// `.statusBar`-level panel that collapses when the pointer leaves it is a fight nobody wins:
/// the menu takes the pointer, the notch collapses out from under it, and the user is left with
/// a menu floating over the desktop attached to nothing. Every choice here has three or four
/// values, so cycling costs at most three clicks and never leaves the panel.
///
/// The value rolls over like a split-flap counter: the old one leaves upwards and the new one
/// springs in from below, inside a field that clips them both.
@MainActor
private struct SettingsChoiceRow<Option: SettingsOption>: View {
    let label: String
    @Binding var selection: Option
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(reduceMotion ? Theme.Motion.content : Theme.Motion.Settings.roll) {
                selection = selection.next
            }
        } label: {
            HStack(spacing: Theme.Metrics.Settings.labelSpacing) {
                // Primary, like a switched-on toggle's: a choice always holds a value, and at
                // secondary these rows read as disabled beside the toggles around them.
                Text(label)
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: .zero)

                ZStack {
                    Text(selection.label)
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(1)
                        .id(selection.id)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .move(edge: .top).combined(with: .opacity)
                                )
                        )
                }
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
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: Theme.Metrics.Settings.choiceCornerRadius,
                        style: .continuous
                    )
                )
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
///
/// The knob squashes and stretches: it widens towards where it is going while it travels, then
/// snaps back to round as it lands on an under-damped spring.
@MainActor
private struct SettingsSwitch: View {
    let isOn: Bool
    var animated = true

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
                Capsule(style: .continuous)
                    .fill(isOn ? Theme.Colors.surface : Theme.Colors.textSecondary)
                    .frame(width: knobSide, height: knobSide)
                    .keyframeAnimator(initialValue: CGFloat(1), trigger: isOn) { knob, stretch in
                        // Anchored on the side it is heading for, so the stretch leads.
                        knob.scaleEffect(x: animated ? stretch : 1, y: 1, anchor: isOn ? .trailing : .leading)
                    } keyframes: { _ in
                        CubicKeyframe(Theme.Motion.Settings.knobStretch, duration: Theme.Motion.Settings.knobStretchDuration)
                        SpringKeyframe(1, duration: Theme.Motion.Settings.knobSettleDuration)
                    }
                    .padding(Theme.Metrics.Settings.switchKnobInset)
            }
            .frame(
                width: Theme.Metrics.Settings.switchWidth,
                height: Theme.Metrics.Settings.switchHeight
            )
            .animation(animated ? Theme.Motion.Settings.knob : Theme.Motion.content, value: isOn)
    }
}

/// Four 1pt sparks thrown off the trailing end of a switch as it turns on.
///
/// Drawn at rest as nothing: progress sits at 0 before the first trigger and at 1 after each
/// burst, and both ends are fully transparent.
@MainActor
private struct SparkBurst: View {
    let trigger: Int

    /// Fanned across the right-hand half-circle, so they fly away from the panel's content.
    private static let angles: [Double] = [-60, -20, 20, 60]

    var body: some View {
        // Read here, not inside the keyframe closure: that closure is `@Sendable`, and `Theme`
        // is main-actor isolated.
        let sparkDistance = Theme.Motion.Settings.sparkDistance
        return ZStack {
            ForEach(Self.angles, id: \.self) { angle in
                Rectangle()
                    .fill(Theme.Colors.textPrimary)
                    .frame(width: 1, height: 1)
                    .keyframeAnimator(initialValue: CGFloat(0), trigger: trigger) { spark, progress in
                        let radians = angle * .pi / 180
                        let distance = sparkDistance * progress
                        spark
                            .offset(x: cos(radians) * distance, y: sin(radians) * distance)
                            .opacity(progress > 0 && progress < 1 ? Double(1 - progress) : 0)
                    } keyframes: { _ in
                        CubicKeyframe(1, duration: Theme.Motion.Settings.sparkDuration)
                    }
            }
        }
        .frame(width: 1, height: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Options

/// What a cycling choice row needs from its enum. The option enums in `NotchSettings` conform;
/// nothing else should, because `next` wrapping past the end is only sensible for a set small
/// enough to click through.
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
extension MediaPlayers: SettingsOption {}
extension PanelSize: SettingsOption {}
extension AnimationSpeed: SettingsOption {}
