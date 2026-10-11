import SwiftUI

/// The words and controls of the first-launch intro. The mascot, the stars and every pixel in
/// flight are drawn by `NotchFX`; this view is only what has to be read or clicked.
///
/// Everything is placed at absolute positions in the band (`Theme.Metrics.Onboarding`) rather
/// than stacked, because the director streams pixels into the checkboxes and has to know where
/// they are without asking the layout.
@MainActor
struct OnboardingView: View {
    let director: OnboardingDirector
    @ObservedObject var integrations: AgentIntegrationManager

    private var layout: Theme.Metrics.Onboarding.Type { Theme.Metrics.Onboarding.self }
    private var band: CGSize { Theme.Metrics.onboardingBandSize }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            switch director.beat {
            case .greeting:
                greeting.transition(.opacity)
            case .consent:
                consent.transition(.opacity)
            case .intro, .leaving:
                EmptyView()
            }
        }
        .frame(width: band.width, height: band.height, alignment: .topLeading)
        .foregroundStyle(Theme.Colors.textPrimary)
        .animation(Theme.Motion.content, value: director.beat)
    }

    // MARK: Hello

    private var greeting: some View {
        VStack(spacing: layout.bodyLineSpacing * 2) {
            TypedText(text: "hi, i'm notch.", start: director.greetingAt)
                .font(Theme.Text.headline)
            TypedText(text: "i keep an eye on your coding agents.", start: director.subtitleAt)
                .font(Theme.Text.body)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .frame(width: band.width)
        .offset(y: layout.greetingTop)
    }

    // MARK: The ask

    private var consent: some View {
        ZStack(alignment: .topLeading) {
            Text("let me watch your coding agents?")
                .font(Theme.Text.headline)
                .offset(x: layout.consentLeading, y: layout.titleTop)

            VStack(alignment: .leading, spacing: layout.bodyLineSpacing) {
                Text("i add one small hook so they can ping me when they stop.")
                Text("your other hooks stay. a backup is saved. undo in settings.")
            }
            .font(Theme.Text.body)
            .foregroundStyle(Theme.Colors.textSecondary)
            .offset(x: layout.consentLeading, y: layout.bodyTop)

            if director.rows.isEmpty {
                Text("no agents found yet. i'll hook them up when they show up.")
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .offset(x: layout.consentLeading, y: layout.rowsTop + 4)
            }
            ForEach(Array(director.rows.enumerated()), id: \.element.id) { index, row in
                let origin = director.rowOrigin(index)
                rowView(row)
                    .offset(x: origin.x, y: origin.y)
            }

            footer
                .offset(x: layout.consentLeading, y: layout.buttonsTop)
        }
    }

    private func rowView(_ row: OnboardingDirector.Row) -> some View {
        let connected = row.wasConnected || row.connectedAt != nil
        let tint = connected ? (row.error == nil ? Theme.Colors.Status.done : Theme.Colors.Status.needsApproval) : Theme.Colors.textPrimary
        return Button {
            director.toggle(row)
        } label: {
            HStack(spacing: .zero) {
                ZStack {
                    RoundedRectangle(cornerRadius: layout.checkboxCornerRadius, style: .continuous)
                        .strokeBorder(row.isOn || connected ? tint : Theme.Colors.textTertiary, lineWidth: 1.2)
                    if row.isOn || connected {
                        RoundedRectangle(cornerRadius: layout.checkboxCornerRadius / 2, style: .continuous)
                            .fill(tint)
                            .padding(3)
                    }
                }
                .frame(width: layout.checkboxSize, height: layout.checkboxSize)
                .padding(.trailing, Theme.Metrics.collapsedContentSpacing * 1.5)

                Text(row.agent.displayName)
                    .foregroundStyle(row.isOn || connected ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)
                    .frame(
                        width: (director.isTwoColumn ? layout.compactNameColumn : layout.nameColumn) - layout.checkboxSize,
                        alignment: .leading
                    )
                    .lineLimit(1)

                Group {
                    if let error = row.error {
                        Text("couldn't hook: \(error)")
                            .foregroundStyle(Theme.Colors.Status.needsApproval)
                    } else if row.wasConnected {
                        Text("already hooked ✓")
                            .foregroundStyle(Theme.Colors.Status.done)
                    } else if row.connectedAt != nil {
                        TypedText(text: "hooked ✓", start: row.connectedAt)
                            .foregroundStyle(Theme.Colors.Status.done)
                    } else {
                        Text("~/" + row.agent.configurationRelativePath)
                            .foregroundStyle(Theme.Colors.textTertiary)
                    }
                }
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: director.isTwoColumn ? layout.compactStatusWidth : nil, alignment: .leading)
            }
            .font(Theme.Text.body)
            .frame(height: layout.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(row.wasConnected || director.hasAnswered)
        .accessibilityLabel(row.agent.displayName)
        .accessibilityValue(connected ? "Connected" : row.isOn ? "Will connect" : "Skipped")
    }

    @ViewBuilder
    private var footer: some View {
        if let afterword = director.afterword {
            TypedText(text: afterword, start: director.afterwordAt)
                .font(Theme.Text.body)
                .foregroundStyle(director.afterwordIsGood ? Theme.Colors.Status.done : Theme.Colors.textSecondary)
                .padding(.top, Theme.Metrics.Control.verticalPadding)
        } else {
            HStack(spacing: Theme.Metrics.collapsedContentSpacing * 1.5) {
                Button("not now") { director.notNow() }
                    .buttonStyle(NotchButtonStyle())
                Button(director.hasSomethingToConnect ? "connect ⏎" : "continue ⏎") { director.connect() }
                    .buttonStyle(OnboardingPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(director.hasAnswered)
        }
    }
}

/// Text that types itself out from `start`, at `Theme.Motion.Onboarding.typeRate`.
private struct TypedText: View {
    let text: String
    let start: TimeInterval?

    var body: some View {
        if let start {
            TimelineView(.animation(paused: isFinished(start))) { timeline in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate - start
                let count = max(0, Int(elapsed * Theme.Motion.Onboarding.typeRate))
                // The full string is laid out invisibly underneath so the line never reflows as
                // it types.
                ZStack(alignment: .leading) {
                    Text(text).hidden()
                    Text(String(text.prefix(count)))
                }
                .accessibilityLabel(text)
            }
        } else {
            Text(text).hidden()
        }
    }

    private func isFinished(_ start: TimeInterval) -> Bool {
        NotchFX.now - start > Double(text.count) / Theme.Motion.Onboarding.typeRate + 0.1
    }
}

/// The intro's one filled button: ink on black, so the answer that touches the user's config
/// is unmistakably the one being offered.
private struct OnboardingPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Text.body)
            .foregroundStyle(Theme.Colors.surface)
            .padding(.horizontal, Theme.Metrics.Control.horizontalPadding)
            .padding(.vertical, Theme.Metrics.Control.verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.Control.cornerRadius, style: .continuous)
                    .fill(Theme.Colors.ink.opacity(configuration.isPressed ? 0.8 : 1))
            )
            .contentShape(Rectangle())
    }
}
