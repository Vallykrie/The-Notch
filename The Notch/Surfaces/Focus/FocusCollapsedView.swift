import SwiftUI

/// The focus timer on the closed notch.
///
/// The countdown always has the trailing shoulder: the timer is the one live thing the user
/// started on purpose and is watching, so it gets a fixed home. The leading shoulder shows the
/// focus mascot only when nothing else is live; with an agent running it is the agent's sprite
/// instead, so one blob never means two things at once. See `LiveActivityLayout`.

/// The mascot at shoulder size, filling with the phase.
@MainActor
struct FocusShoulderMascotView: View {
    @ObservedObject var timer: FocusTimer

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                sprite(at: Date())
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in sprite(at: context.date) }
            }
        }
        .frame(width: CGFloat(AgentActivityGlyph.columns) * pixel, height: CGFloat(AgentActivityGlyph.rows) * pixel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Focus timer")
    }

    private var pixel: CGFloat {
        (Theme.Metrics.Agents.mascotCollapsedSize / CGFloat(AgentActivityGlyph.rows)).rounded(.down)
    }

    private func sprite(at now: Date) -> some View {
        var figure = AgentActivityGlyph.Posed()
        figure.legs = nil
        switch timer.run {
        case .running where timer.phase == .focus:
            // Typing: the antennae flick on alternate keystrokes.
            let left = Int(now.timeIntervalSinceReferenceDate / 0.2) % 2 == 0
            figure.eyes = .narrow
            figure.eyeShift = 1
            figure.antennaLeft = left ? 2 : 1
            figure.antennaRight = left ? 1 : 2
        case .running:
            figure.eyes = .narrow
        case .paused, .waiting:
            figure.brightness = Theme.Metrics.Focus.pausedBrightness
        case .setup:
            break
        }
        return GlyphCellsView(
            cells: FocusScene.shoulderCells(figure: figure, fill: timer.progress(at: now)),
            pixel: pixel
        )
        .foregroundStyle(timer.phase == .focus ? Theme.Colors.Focus.focus : Theme.Colors.Focus.rest)
    }
}

/// The countdown and a 2pt line under it showing how far through the phase.
@MainActor
struct FocusCountdownShoulderView: View {
    @ObservedObject var timer: FocusTimer

    private typealias Metrics = Theme.Metrics.Focus

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let now = context.date
            let held = timer.run != .running
            // A paused or waiting timer blinks slowly at the paused brightness, so a forgotten
            // pause is noticeable without nagging.
            let blinkOff = held && Int(now.timeIntervalSinceReferenceDate / 0.6) % 2 == 0
            VStack(alignment: .trailing, spacing: Metrics.lineSpacing) {
                Text(FocusExpandedView.clock(timer.remaining(at: now)))
                    .font(Theme.Text.body)
                    .monospacedDigit()
                    .opacity(blinkOff ? Metrics.pausedBrightness : 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Colors.textPrimary.opacity(Metrics.stripTrackOpacity))
                    Capsule()
                        .fill(timer.phase == .focus ? Theme.Colors.Focus.focus : Theme.Colors.Focus.rest)
                        .frame(width: Metrics.lineWidth * timer.progress(at: now))
                }
                .frame(width: Metrics.lineWidth, height: Metrics.lineHeight)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Focus timer, \(FocusExpandedView.clock(timer.remaining())) left")
    }
}
