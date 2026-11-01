import SwiftUI

/// The Focus tab: the mascot's desk on the left; two rulers before Start, then only the
/// countdown and the set's strip.
///
/// The rulers are for *setting* the time and nothing else. Once the timer runs they give way
/// to the countdown — a ruler creeping toward zero under a needle was the precise reading,
/// but the countdown already is that, and a control that stays on screen while it is locked
/// invites a drag that does nothing. Reset brings them back. See
/// `docs/design/pomodoro-ui-v4.html`, option 3.
@MainActor
struct FocusExpandedView: View {
    @ObservedObject var timer: FocusTimer

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Which ruler is being dragged, and when it last moved — the mascot looks at it.
    @State private var activeRuler: FocusScene.Ruler?
    @State private var rulerMovedAt = Date.distantPast

    private typealias Metrics = Theme.Metrics.Focus

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.sceneSpacing) {
            FocusMascotView(
                timer: timer,
                activeRuler: activeRuler,
                rulerMovedAt: rulerMovedAt
            )
            .frame(
                width: CGFloat(FocusScene.columns) * Metrics.sceneCell,
                height: CGFloat(FocusScene.rows) * Metrics.sceneCell
            )

            ZStack(alignment: .topLeading) {
                if timer.run == .setup {
                    setup
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        ))
                } else {
                    running
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(reduceMotion ? Theme.Motion.content : Theme.Motion.Focus.swap, value: timer.run == .setup)
        }
        .foregroundStyle(Theme.Colors.textPrimary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, Theme.Metrics.expandedHorizontalPadding)
        .padding(.bottom, Theme.Metrics.expandedVerticalPadding)
    }

    // MARK: Setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: Metrics.rulerRowSpacing) {
            rulerRow(
                label: "FOCUS",
                tint: Theme.Colors.Focus.focus,
                value: $timer.focusMinutes,
                range: FocusTimer.focusRange,
                pointsPerMinute: Metrics.focusRulerPointsPerMinute,
                ruler: .focus
            )
            rulerRow(
                label: "BREAK",
                tint: Theme.Colors.Focus.rest,
                value: $timer.breakMinutes,
                range: FocusTimer.breakRange,
                pointsPerMinute: Metrics.breakRulerPointsPerMinute,
                ruler: .rest
            )
            Spacer(minLength: .zero)
            HStack(spacing: 8) {
                Text(setSummary)
                    .font(Theme.Text.micro)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: .zero)
                Button("Start") { timer.toggle() }
                    .buttonStyle(NotchButtonStyle(role: .primary(tint: Theme.Colors.textPrimary), size: .compact))
                    .keyboardShortcut(.space, modifiers: [])
            }
            .frame(height: Metrics.footerHeight)
        }
    }

    private func rulerRow(
        label: String,
        tint: Color,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        pointsPerMinute: CGFloat,
        ruler: FocusScene.Ruler
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .font(Theme.Text.micro)
                    .foregroundStyle(tint)
                Text("\(value.wrappedValue) min")
                    .font(Typography.font(size: Metrics.rulerValueSize))
                    .contentTransition(.numericText())
                    .animation(Theme.Motion.content, value: value.wrappedValue)
            }
            FocusRulerView(
                value: value,
                range: range,
                pointsPerMinute: pointsPerMinute,
                tint: tint
            ) { dragging in
                activeRuler = dragging ? ruler : nil
                rulerMovedAt = Date()
            }
            .frame(height: Metrics.rulerHeight)
        }
    }

    private var setSummary: String {
        let rounds = "\(timer.rounds) rounds"
        guard let long = timer.longBreakMinutes else { return "\(rounds) · no long break" }
        return "\(rounds) · long break \(long) min after the \(ordinal(timer.rounds))"
    }

    private func ordinal(_ n: Int) -> String {
        switch n {
        case 1: "1st"
        case 2: "2nd"
        case 3: "3rd"
        default: "\(n)th"
        }
    }

    // MARK: Running

    private var running: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let now = context.date
            VStack(alignment: .leading, spacing: .zero) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Self.clock(timer.remaining(at: now)))
                        .font(Typography.font(size: Metrics.countdownSize))
                        .monospacedDigit()
                        .opacity(timer.run == .paused ? Theme.Metrics.Focus.pausedBrightness : 1)
                    Text(phaseLabel)
                        .font(Theme.Text.caption)
                        .foregroundStyle(phaseTint)
                        .lineLimit(1)
                }
                .padding(.top, -6)

                FocusStripView(timer: timer)
                    .frame(height: Metrics.stripTop + Metrics.stripHeight + 12)

                Spacer(minLength: .zero)

                HStack(spacing: 6) {
                    Text("\(timer.completed(on: now)) rounds today")
                        .font(Theme.Text.micro)
                        .foregroundStyle(Theme.Colors.textTertiary)
                    Spacer(minLength: .zero)
                    Button("Reset") { timer.reset() }
                        .buttonStyle(NotchButtonStyle(role: .tertiary, size: .compact))
                    Button("Skip") { timer.skip() }
                        .buttonStyle(NotchButtonStyle(role: .tertiary, size: .compact))
                    Button(primaryTitle) { timer.toggle() }
                        .buttonStyle(NotchButtonStyle(role: .primary(tint: Theme.Colors.textPrimary), size: .compact))
                        .keyboardShortcut(.space, modifiers: [])
                }
                .frame(height: Metrics.footerHeight)
            }
        }
    }

    private var primaryTitle: String {
        switch timer.run {
        case .running: "Pause"
        case .paused: "Resume"
        case .waiting: timer.phase == .focus ? "Start round \(timer.round)" : "Start break"
        case .setup: "Start"
        }
    }

    private var phaseLabel: String {
        let name = switch timer.phase {
        case .focus: "Focus"
        case .shortBreak: "Break"
        case .longBreak: "Long break"
        }
        let state = switch timer.run {
        case .paused: " · paused"
        case .waiting: " · ready"
        default: ""
        }
        return "\(name) · round \(timer.round)/\(timer.rounds)\(state)"
    }

    private var phaseTint: Color {
        timer.phase == .focus ? Theme.Colors.Focus.focus : Theme.Colors.Focus.rest
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded(.up))
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}

// MARK: - Mascot

/// The scene, on the display link.
@MainActor
struct FocusMascotView: View {
    @ObservedObject var timer: FocusTimer
    var activeRuler: FocusScene.Ruler?
    var rulerMovedAt: Date = .distantPast

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.debugMotionTime) private var debugMotionTime
    @State private var clockStart = Date()

    var body: some View {
        Group {
            if let pinned = debugMotionTime {
                scene(at: clockStart.addingTimeInterval(pinned))
            } else if reduceMotion {
                scene(at: clockStart)
            } else {
                TimelineView(.animation) { context in scene(at: context.date) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Focus mascot")
    }

    private func scene(at now: Date) -> some View {
        let (mode, since) = mode(at: now)
        let fill = timer.progress(at: now)
        // Seconds of this round already worked: the keystroke clock, which stops when paused.
        let typed = timer.phase == .focus ? fill * timer.duration(of: .focus) : 0
        let cells = FocusScene.cells(
            mode: mode,
            time: now.timeIntervalSince(clockStart),
            phaseTime: now.timeIntervalSince(since),
            typed: typed,
            fill: fill
        )
        return GlyphCellsView(cells: cells, pixel: Theme.Metrics.Focus.sceneCell)
            .foregroundStyle(hue(for: mode))
    }

    /// What the mascot is doing, and since when.
    private func mode(at now: Date) -> (FocusScene.Mode, Date) {
        if let ended = timer.lastEnded, ended.phase == .focus,
           now.timeIntervalSince(ended.at) < Theme.Motion.Focus.cheer {
            return (.done, ended.at)
        }
        switch timer.run {
        case .setup:
            let glancing = activeRuler != nil
                || now.timeIntervalSince(rulerMovedAt) < Theme.Motion.Focus.rulerGlance
            return (.ready(ruler: glancing ? (activeRuler ?? .focus) : nil), clockStart)
        case .waiting:
            return (.waiting, clockStart)
        case .paused:
            return (.paused, clockStart)
        case .running:
            if let started = timer.startedAt, timer.phase == .focus,
               now.timeIntervalSince(started) < Theme.Motion.Focus.hop {
                return (.hop, started)
            }
            switch timer.phase {
            case .focus: return (.typing(rush: timer.remaining(at: now) < 60), clockStart)
            case .shortBreak: return (.tea, clockStart)
            case .longBreak: return (.nap, clockStart)
            }
        }
    }

    private func hue(for mode: FocusScene.Mode) -> Color {
        switch mode {
        case .ready: Theme.Colors.Focus.idle
        case .done, .hop: Theme.Colors.Focus.focus
        default: timer.phase == .focus ? Theme.Colors.Focus.focus : Theme.Colors.Focus.rest
        }
    }
}

// MARK: - Ruler

/// A kitchen-timer tape: minutes slide under a fixed needle as you drag. Dragging left pulls
/// out more minutes, the way you would wind the real thing.
@MainActor
struct FocusRulerView: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let pointsPerMinute: CGFloat
    let tint: Color
    var onDragging: (Bool) -> Void = { _ in }

    @State private var dragStart: Int?

    private typealias Metrics = Theme.Metrics.Focus

    var body: some View {
        Canvas { context, size in
            let needle = Metrics.needleOffset
            let zero = needle - CGFloat(value) * pointsPerMinute
            let top: CGFloat = 4
            let band: CGFloat = 13

            // The minutes set, as a faint band from the lowest allowed value to the needle.
            let bandStart = zero + CGFloat(range.lowerBound) * pointsPerMinute
            context.fill(
                Path(CGRect(x: bandStart, y: top, width: needle - bandStart, height: band)),
                with: .color(tint.opacity(0.13))
            )
            for minute in 0 ... range.upperBound {
                let x = (zero + CGFloat(minute) * pointsPerMinute).rounded()
                guard x > -10, x < size.width + 10 else { continue }
                let five = minute % 5 == 0
                let inRange = minute >= range.lowerBound
                let alpha = !inRange ? 0.08 : minute <= value ? 0.7 : 0.28
                context.fill(
                    Path(CGRect(x: x, y: top, width: 1, height: five ? 9 : 4)),
                    with: .color(.white.opacity(alpha))
                )
                if five, inRange {
                    context.draw(
                        Text("\(minute)").font(Theme.Text.micro).foregroundStyle(.white.opacity(0.45)),
                        at: CGPoint(x: x, y: size.height - 4)
                    )
                }
            }
            context.fill(
                Path(CGRect(x: needle - Metrics.needleWidth / 2, y: 1, width: Metrics.needleWidth, height: 17)),
                with: .color(tint)
            )
            var cap = Path()
            cap.move(to: CGPoint(x: needle - 3, y: 0))
            cap.addLine(to: CGPoint(x: needle + 3, y: 0))
            cap.addLine(to: CGPoint(x: needle, y: 3))
            context.fill(cap, with: .color(tint))
        }
        // Fade the tape out at both ends, so it reads as a strip passing under a window.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.05),
                    .init(color: .black, location: 0.85),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { drag in
                    if dragStart == nil {
                        dragStart = value
                        onDragging(true)
                    }
                    let start = dragStart ?? value
                    let minutes = Int((CGFloat(start) - drag.translation.width / pointsPerMinute).rounded())
                    let clamped = min(max(minutes, range.lowerBound), range.upperBound)
                    if clamped != value { value = clamped }
                }
                .onEnded { _ in
                    dragStart = nil
                    onDragging(false)
                }
        )
        .onHover { inside in
            if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
        .accessibilityElement()
        .accessibilityLabel("Minutes")
        .accessibilityValue("\(value) minutes")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + 1, range.upperBound)
            case .decrement: value = max(value - 1, range.lowerBound)
            @unknown default: break
            }
        }
    }
}

// MARK: - Strip + walker

/// The whole set as one strip of blocks — focus amber, breaks green — with the current block
/// filling, and the mascot walking along the top of it: walking through focus, sitting through
/// breaks. Where it stands is how far through the set you are.
@MainActor
struct FocusStripView: View {
    @ObservedObject var timer: FocusTimer

    private typealias Metrics = Theme.Metrics.Focus

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            GeometryReader { proxy in
                let now = context.date
                let layout = segments(width: proxy.size.width)
                ZStack(alignment: .topLeading) {
                    Canvas { canvas, _ in
                        for (index, segment) in layout.enumerated() {
                            let tint = segment.phase == .focus ? Theme.Colors.Focus.focus : Theme.Colors.Focus.rest
                            let rect = CGRect(x: segment.x, y: Metrics.stripTop, width: segment.width, height: Metrics.stripHeight)
                            canvas.fill(Path(rect), with: .color(tint.opacity(Metrics.stripTrackOpacity)))
                            let done = index < timer.planIndex ? 1 : index == timer.planIndex ? timer.progress(at: now) : 0
                            canvas.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width * done, height: rect.height)), with: .color(tint))
                        }
                    }

                    Text("set ends ≈ \(timer.setEnds(at: now).formatted(date: .omitted, time: .shortened))")
                        .font(Theme.Text.micro)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .offset(y: Metrics.stripTop + Metrics.stripHeight + 3)

                    walker(at: now, x: walkerX(layout: layout, now: now))
                }
            }
        }
    }

    private struct Segment {
        let phase: FocusTimer.Phase
        let x: CGFloat
        let width: CGFloat
    }

    private func segments(width: CGFloat) -> [Segment] {
        let plan = timer.plan
        let total = plan.reduce(0) { $0 + timer.duration(of: $1) }
        guard total > 0 else { return [] }
        let usable = width - Metrics.stripGap * CGFloat(plan.count - 1)
        var x: CGFloat = 0
        return plan.map { phase in
            let w = usable * timer.duration(of: phase) / total
            defer { x += w + Metrics.stripGap }
            return Segment(phase: phase, x: x, width: w)
        }
    }

    private func walkerX(layout: [Segment], now: Date) -> CGFloat {
        guard layout.indices.contains(timer.planIndex) else { return 0 }
        let segment = layout[timer.planIndex]
        return segment.x + segment.width * timer.progress(at: now)
    }

    private func walker(at now: Date, x: CGFloat) -> some View {
        let t = now.timeIntervalSinceReferenceDate
        let stepping = timer.run == .running && timer.phase == .focus
        var figure = AgentActivityGlyph.Posed()
        if timer.phase == .focus {
            let step = Int(t * 4) % 2
            figure.legs = stepping ? step : 0
            figure.bob = stepping && step == 1 ? -1 : 0
            figure.antennaLeft = 2
            figure.antennaRight = 2
            figure.eyeShift = 1
        } else {
            // Sitting it out: legs tucked, squashed, antennae wagging slowly.
            let wag = Int(t / 1.4) % 2 == 0
            figure.legs = nil
            figure.squashed = true
            figure.eyes = .narrow
            figure.antennaLeft = wag ? 2 : 1
            figure.antennaRight = wag ? 1 : 2
        }
        if timer.run != .running { figure.brightness = Metrics.pausedBrightness }
        let headroom = AgentActivityGlyph.headroom
        let pixel = Metrics.walkerCell
        let width = CGFloat(AgentActivityGlyph.columns) * pixel
        let height = CGFloat(AgentActivityGlyph.rows + headroom) * pixel
        return GlyphCellsView(
            cells: AgentActivityGlyph.cells(for: figure, headroom: headroom),
            pixel: pixel,
            rowOffset: headroom
        )
        .foregroundStyle(timer.phase == .focus ? Theme.Colors.Focus.focus : Theme.Colors.Focus.rest)
        .frame(width: width, height: height)
        .offset(x: x - width / 2, y: Metrics.stripTop - height + (figure.legs == nil ? 2 * pixel : 0))
    }
}
