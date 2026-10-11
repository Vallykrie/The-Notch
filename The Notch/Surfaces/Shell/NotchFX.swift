import SwiftUI

/// Everything the notch draws that is not a view: liquid drops, stars, the mascot's pixels in
/// flight, shock rings, sparks, confetti, rim light, and the lyric pill.
///
/// These are effects rather than views because none of them has a layout. A drop is a circle at
/// a position that is a function of time; a spark is a point on a ballistic arc. Modelling them
/// as SwiftUI views would have meant hundreds of transient views with transitions and identities
/// for things that live for under a second and never take a click.
///
/// So each effect is a small value describing its whole life — where it starts, what it does,
/// when it ends — and three canvases (`NotchFXLayers`) sample them on the display link. Almost
/// everything is closed-form: the position at time `t` is computed, not integrated, so an effect
/// costs nothing between frames and two canvases sampling the same instant always agree. The
/// lyric pill is the exception, because it reacts to the pointer; it is stepped once per frame
/// by `LyricPill`.
///
/// Coordinates are the panel's own: top-left origin, the notch's top edge at `y == 0`, and its
/// centre at `panelSize.width / 2`. Views that the effects attach to (a mascot on the shoulder,
/// a mascot on a card) report their frames in the `NotchFX.space` coordinate space.
@Observable
@MainActor
final class NotchFX {
    nonisolated static let space = "notch-panel"

    /// The mascots an effect can fly between.
    enum MascotRole: Hashable {
        case shoulder
        case card
    }

    // MARK: Geometry

    /// Kept current by `NotchRootView`. Not observed: the canvases read it while drawing.
    @ObservationIgnored var panelSize: CGSize = .zero
    /// The resting silhouette's height, for the lyric pill's drip.
    @ObservationIgnored var collapsedSize: CGSize = Theme.Metrics.fauxNotchSize
    /// Where the pointer is, in panel space. Supplied by the coordinator.
    @ObservationIgnored var pointer: () -> CGPoint? = { nil }
    @ObservationIgnored var reduceMotion = false
    /// Where each mascot role is drawn, in panel space. Written by `mascotAnchor(_:)`.
    @ObservationIgnored var anchors: [MascotRole: CGRect] = [:]

    var centerX: CGFloat { panelSize.width / 2 }

    /// A silhouette of `size`, hanging from the top centre of the panel.
    func silhouette(_ size: CGSize) -> CGRect {
        CGRect(x: centerX - size.width / 2, y: 0, width: size.width, height: size.height)
    }

    /// The silhouette's *visible body*: the notch's side walls sit inside its frame by the top
    /// corner radius, because the top corners flare outward into the bezel. Anything that should
    /// appear to come off the notch's edge — sparks, confetti — starts from here, not the frame.
    func body(_ size: CGSize, topRadius: CGFloat) -> CGRect {
        silhouette(size).insetBy(dx: topRadius, dy: 0)
    }

    /// The notch a drop hangs from, as the metaball pass draws it.
    struct Attachment: Equatable {
        let rect: CGRect
        let topRadius: CGFloat
        let bottomRadius: CGFloat

        /// The real silhouette, a little inside the crisp one so the drop seems to grow from
        /// under the edge. It used to be a rounded rectangle the size of the *frame*, which ran
        /// past the notch's walls by the top corner radius on each side — 19pt either side of the
        /// open card — and popped a wider black slab out from behind the notch for every drip.
        var path: Path {
            let inset = Theme.Metrics.Liquid.attachInset
            return Path(NotchShape.cgPath(
                in: CGRect(x: rect.minX + inset, y: rect.minY, width: rect.width - inset * 2, height: rect.height - inset),
                topCornerRadius: topRadius,
                bottomCornerRadius: max(0, bottomRadius - inset)
            ))
        }
    }

    func attachment(_ size: CGSize, expanded: Bool) -> Attachment {
        Attachment(
            rect: silhouette(size),
            topRadius: expanded ? Theme.Metrics.expandedTopCornerRadius : Theme.Metrics.collapsedTopCornerRadius,
            bottomRadius: expanded ? Theme.Metrics.expandedBottomCornerRadius : Theme.Metrics.collapsedBottomCornerRadius
        )
    }

    // MARK: Live effects

    /// Mascots that are hidden because their pixels are in the air.
    var hidden: Set<MascotRole> = []
    private(set) var drops: [Drop] = []
    private(set) var stars: [Star] = []
    private(set) var pixels: [Pixel] = []
    private(set) var sparks: [Spark] = []
    private(set) var rings: [Ring] = []
    private(set) var rims: [Rim] = []
    var bigMascot: BigMascot?
    @ObservationIgnored let pill = LyricPill()
    /// Whether the pill is anywhere on screen, observed so the canvases keep ticking for it.
    private(set) var pillActive = false

    var needsLiquidFrames: Bool { !drops.isEmpty || pillActive }
    var needsInnerFrames: Bool { !stars.isEmpty || !pixels.isEmpty || bigMascot != nil }
    var needsOuterFrames: Bool { !sparks.isEmpty || !rings.isEmpty || pillActive }
    var needsRimFrames: Bool { !rims.isEmpty }

    static var now: TimeInterval { Date().timeIntervalSinceReferenceDate }

    /// Drops everything. Used when the intro is replayed or the display changes underneath.
    func reset() {
        drops = []
        stars = []
        pixels = []
        sparks = []
        rings = []
        rims = []
        bigMascot = nil
        hidden = []
        pill.reset()
        pillActive = false
    }

    // MARK: Liquid

    /// A blob in the metaball pass. `attach` is the silhouette it grows out of, drawn into the
    /// same pass so the two merge; `nil` for a drop that has let go.
    struct Drop {
        var x: Track
        var y: Track
        var r: Track
        var attach: Attachment?
        let end: TimeInterval
    }

    /// Beads of liquid forming along the bottom edge of `rect` and stretching down off it.
    func melt(from notch: Attachment) {
        let rect = notch.rect
        let now = Self.now
        let offsets: [CGFloat] = [-64, -33, -2, 30, 61]
        for (index, dx) in offsets.enumerated() {
            let start = now + Double(index) * 0.07
            var r = Track(0)
            r.retarget(9 + CGFloat(index % 3) * 2.6, at: start, .damped(Theme.Motion.Liquid.dropGrow))
            var y = Track(rect.maxY + 2)
            y.retarget(rect.maxY + 26 + .random(in: 0 ... 26), at: start, .bezier(Theme.Motion.Liquid.accelerate, Theme.Motion.Liquid.dropFall))
            drops.append(Drop(x: Track(rect.midX + dx), y: y, r: r, attach: notch, end: .infinity))
        }
    }

    /// Every hanging drop is drawn up into a silhouette that is opening over it, then dropped.
    func swallowDrops(into depth: CGFloat) {
        let now = Self.now
        drops = drops.map { drop in
            var drop = drop
            drop.y.retarget(depth, at: now, .bezier(Theme.Motion.Liquid.glide, Theme.Motion.Liquid.gulp + 0.15))
            drop.r.retarget(20, at: now, .damped(Theme.Motion.Liquid.pillGather))
            return Drop(x: drop.x, y: drop.y, r: drop.r, attach: drop.attach, end: now + 0.6)
        }
        schedulePrune(after: 0.6)
    }

    /// A single drop forming under `rect` and hanging there. Returns its index for `gulp`.
    func hangDrop(under notch: Attachment, radius: CGFloat, hang: CGFloat, life: TimeInterval = .infinity) {
        let rect = notch.rect
        let now = Self.now
        var r = Track(0)
        r.retarget(radius, at: now, .damped(Theme.Motion.Liquid.dropGrow))
        var y = Track(rect.maxY - 2)
        y.retarget(rect.maxY + hang, at: now + 0.24, .bezier(Theme.Motion.Liquid.glide, 0.5))
        if life.isFinite {
            // A nudge drop: it hangs, then is drawn back up and shrinks into the edge.
            let back = now + life - 0.4
            y.retarget(rect.maxY - 6, at: back, .bezier(Theme.Motion.Liquid.glide, 0.3))
            r.retarget(0, at: back, .bezier(Theme.Motion.Liquid.accelerate, 0.35))
            schedulePrune(after: life)
        }
        drops.append(Drop(x: Track(rect.midX), y: y, r: r, attach: notch, end: life.isFinite ? now + life : .infinity))
    }

    /// The hanging drops are pulled up into the notch as it opens over them.
    func gulp(depth: CGFloat) {
        swallowDrops(into: depth)
    }

    // MARK: Stars

    struct Star {
        let origin: CGPoint
        let velocity: CGVector
        let born: TimeInterval
        let twinkle: Double
        let phase: Double
        let tint: Color
        let size: CGFloat
        let opacity: Double
        var fadeAt: TimeInterval = .infinity
        var end: TimeInterval = .infinity
        /// Set when the star is pulled into a shape: where it goes and how.
        var seek: Seek?

        struct Seek {
            let start: TimeInterval
            let target: CGPoint
            let response: Double
            let size: CGFloat
            let tint: Color
        }

        func drift(at t: TimeInterval) -> CGPoint {
            let dt = CGFloat(max(0, t - born))
            return CGPoint(x: origin.x + velocity.dx * dt, y: origin.y + velocity.dy * dt)
        }

        func position(at t: TimeInterval) -> CGPoint {
            guard let seek, t > seek.start else { return drift(at: t) }
            let from = drift(at: seek.start)
            let elapsed = t - seek.start
            let spring = (response: seek.response, damping: Theme.Motion.Liquid.starSeekDamping)
            return CGPoint(
                x: Track.damped(from: from.x, to: seek.target.x, spring: spring, elapsed: elapsed),
                y: Track.damped(from: from.y, to: seek.target.y, spring: spring, elapsed: elapsed)
            )
        }
    }

    /// A field of drifting stars across `rect`.
    func spawnStars(_ count: Int, in rect: CGRect, opacity: ClosedRange<Double>, appearOver spread: TimeInterval) {
        let now = Self.now
        let tints = Theme.Colors.starTints
        for index in 0 ..< count {
            stars.append(Star(
                origin: CGPoint(x: .random(in: rect.minX ... rect.maxX), y: .random(in: rect.minY ... rect.maxY)),
                velocity: CGVector(dx: .random(in: -8 ... 8), dy: .random(in: -5 ... 5)),
                born: now + .random(in: 0 ... spread),
                twinkle: .random(in: 2 ... 6),
                phase: .random(in: 0 ... 6),
                tint: tints[index % tints.count],
                size: Double.random(in: 0 ... 1) < 0.15 ? 2 : 1.2,
                opacity: .random(in: opacity)
            ))
        }
    }

    /// Pulls stars into `targets`, one each, staggered so they arrive as a swarm rather than a
    /// snap. Stars beyond the target count keep drifting.
    func gatherStars(into targets: [CGPoint], cellSize: CGFloat, tint: Color) {
        let now = Self.now
        var order = Array(stars.indices).shuffled()
        while order.count < targets.count {
            // Not enough sky: the shortfall is born at the centre of the band, already dim.
            spawnStars(1, in: CGRect(origin: targets[order.count], size: .zero), opacity: 0.4 ... 0.4, appearOver: 0)
            order.append(stars.count - 1)
        }
        for (target, index) in zip(targets, order) {
            stars[index].seek = Star.Seek(
                start: now + .random(in: 0 ... 0.5),
                target: target,
                response: .random(in: Theme.Motion.Liquid.starSeek),
                size: cellSize - 1,
                tint: tint
            )
        }
    }

    /// Removes the stars that became a shape, the instant the real shape replaces them.
    func dropGatheredStars() {
        stars.removeAll { $0.seek != nil }
    }

    func fadeStars(over duration: TimeInterval = 0.3) {
        let now = Self.now
        for index in stars.indices {
            let fade = now + .random(in: 0 ... duration)
            stars[index].fadeAt = fade
            stars[index].end = fade + 0.3
        }
        schedulePrune(after: duration + 0.35)
    }

    // MARK: Pixels in flight

    /// One pixel flying along a cubic from one place to another. The destination can be a
    /// mascot's cell, resolved every frame, so a card that is still settling into place is
    /// tracked rather than missed.
    struct Pixel {
        let from: CGPoint
        let to: Endpoint
        /// Offsets of the two control points from the start and the end.
        let lead: CGVector
        let trail: CGVector
        let start: TimeInterval
        let duration: TimeInterval
        let size: ClosedRange<CGFloat>
        let shrinks: Bool
        let tint: Color

        var end: TimeInterval { start + duration }

        enum Endpoint {
            case point(CGPoint)
            case cell(MascotRole, column: Int, row: Int, fallback: CGPoint)
        }
    }

    /// Streams pixels from `origin` to `target`, for the onboarding's "hooked up" moment.
    /// Returns how long until the last one lands.
    @discardableResult
    func stream(from origin: CGPoint, to target: CGPoint, tint: Color, delay: TimeInterval) -> TimeInterval {
        let now = Self.now
        let timing = Theme.Motion.Attention.self
        let count = timing.streamCount
        for index in 0 ..< count {
            pixels.append(Pixel(
                from: CGPoint(x: origin.x + .random(in: -18 ... 18), y: origin.y + .random(in: -14 ... 14)),
                to: .point(target),
                lead: CGVector(dx: 70, dy: -50),
                trail: CGVector(dx: -60, dy: .random(in: -20 ... 20)),
                start: now + delay + Double(index) * timing.streamStagger,
                duration: timing.streamFlight,
                size: 3.2 ... 3.2,
                shrinks: false,
                tint: tint
            ))
        }
        let landing = delay + Double(count) * timing.streamStagger + timing.streamFlight
        schedulePrune(after: landing + 0.1)
        return landing
    }

    /// The mascot coming apart at one place and rebuilding itself at another, cell for cell.
    ///
    /// Both ends are the same pose, so the pixel that leaves the left antenna is the pixel that
    /// becomes the left antenna — it reads as one creature travelling rather than as one
    /// disappearing and another appearing.
    func transit(
        cells: [AgentActivityGlyph.Cell],
        from source: (origin: CGPoint, pixel: CGFloat),
        to destination: MascotRole,
        fallback: (origin: CGPoint, pixel: CGFloat),
        tint: Color,
        upward: Bool
    ) {
        let now = Self.now
        let timing = Theme.Motion.Attention.self
        for cell in cells {
            let from = CGPoint(
                x: source.origin.x + (CGFloat(cell.column) + 0.5) * source.pixel,
                y: source.origin.y + (CGFloat(cell.row) + 0.5) * source.pixel
            )
            let fallbackPoint = CGPoint(
                x: fallback.origin.x + (CGFloat(cell.column) + 0.5) * fallback.pixel,
                y: fallback.origin.y + (CGFloat(cell.row) + 0.5) * fallback.pixel
            )
            let rowDelay = Double(upward ? 9 - cell.row : cell.row) * timing.transitStagger
            pixels.append(Pixel(
                from: from,
                to: .cell(destination, column: cell.column, row: cell.row, fallback: fallbackPoint),
                lead: upward
                    ? CGVector(dx: -30 + .random(in: -24 ... 24), dy: -14)
                    : CGVector(dx: .random(in: -30 ... 30), dy: 56),
                trail: upward
                    ? CGVector(dx: .random(in: -30 ... 30), dy: 44)
                    : CGVector(dx: -46 + .random(in: -20 ... 20), dy: -12),
                start: now + rowDelay + .random(in: 0 ... 0.06),
                duration: timing.transit + .random(in: -0.08 ... 0.08),
                size: min(source.pixel, fallback.pixel) ... max(source.pixel, fallback.pixel),
                shrinks: source.pixel > fallback.pixel,
                tint: tint
            ))
        }
        schedulePrune(after: timing.transit + 0.4)
    }

    /// Where a destination cell is right now.
    private func resolve(_ endpoint: Pixel.Endpoint) -> CGPoint {
        switch endpoint {
        case let .point(point):
            return point
        case let .cell(role, column, row, fallback):
            guard let rect = anchors[role], rect.height > 0 else { return fallback }
            let pixel = rect.height / CGFloat(AgentActivityGlyph.rows)
            return CGPoint(
                x: rect.minX + (CGFloat(column) + 0.5) * pixel,
                y: rect.minY + (CGFloat(row) + 0.5) * pixel
            )
        }
    }

    // MARK: Sparks and confetti

    struct Spark {
        let origin: CGPoint
        let velocity: CGVector
        let gravity: CGFloat
        let drag: CGFloat
        let born: TimeInterval
        let life: TimeInterval
        let size: CGFloat
        let tint: Color
        /// Confetti tumbles: its width follows `cos` of this rate.
        let spin: Double?

        var end: TimeInterval { born + life }

        /// Linear drag and constant gravity, solved exactly: no integration error, and a spark
        /// drawn by two canvases at the same instant is in the same place in both.
        func position(at t: TimeInterval) -> CGPoint {
            let dt = CGFloat(max(0, t - born))
            let k = max(drag, 0.0001)
            let decay = (1 - exp(-k * dt)) / k
            let terminal = gravity / k
            return CGPoint(
                x: origin.x + velocity.dx * decay,
                y: origin.y + terminal * dt + (velocity.dy - terminal) * decay
            )
        }
    }

    /// Sparks thrown off the bottom edge and corners of `rect`.
    func sparks(off rect: CGRect, tint: Color) {
        let now = Self.now
        let metrics = Theme.Metrics.Attention.self
        for _ in 0 ..< Theme.Motion.Attention.sparkCount {
            let side = Double.random(in: 0 ... 1)
            let x: CGFloat = side < 0.2 ? rect.minX + 4 : side > 0.8 ? rect.maxX - 4 : .random(in: rect.minX + 20 ... rect.maxX - 20)
            let lean = side < 0.2 ? 0.6 : side > 0.8 ? -0.6 : 0
            let angle = Double.pi / 2 + .random(in: -1.1 ... 1.1) + lean
            let speed = CGFloat.random(in: metrics.sparkSpeed)
            sparks.append(Spark(
                origin: CGPoint(x: x, y: rect.maxY),
                velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed),
                gravity: 0,
                drag: 4.2,
                born: now,
                life: .random(in: 0.4 ... 0.8),
                size: .random(in: metrics.sparkSize),
                tint: Double.random(in: 0 ... 1) < 0.3 ? Theme.Colors.ink : tint,
                spin: nil
            ))
        }
        schedulePrune(after: 0.85)
    }

    /// Pixel confetti spilling out of the bottom edge of `rect` onto the desktop.
    func confetti(from rect: CGRect) {
        let now = Self.now
        let metrics = Theme.Metrics.Attention.self
        let tints = Theme.Colors.confetti
        for index in 0 ..< Theme.Motion.Attention.confettiCount {
            sparks.append(Spark(
                origin: CGPoint(x: .random(in: rect.minX + 16 ... rect.maxX - 16), y: rect.maxY - 2),
                velocity: CGVector(dx: .random(in: -240 ... 240), dy: .random(in: 40 ... 260)),
                gravity: metrics.confettiGravity,
                drag: 0.9,
                born: now + .random(in: 0 ... 0.18),
                life: .random(in: Theme.Motion.Attention.confettiLife),
                size: .random(in: metrics.confettiSize),
                tint: tints[index % tints.count],
                spin: .random(in: 6 ... 14)
            ))
        }
        schedulePrune(after: Theme.Motion.Attention.confettiLife.upperBound + 0.2)
    }

    // MARK: Rings and rim light

    struct Ring {
        let born: TimeInterval
        let rect: CGRect
        let topRadius: CGFloat
        let bottomRadius: CGFloat
        let tint: Color
        var end: TimeInterval { born + Theme.Motion.Attention.ringLife }
    }

    /// Shock rings leaving a silhouette of `size`.
    func rings(around size: CGSize, topRadius: CGFloat, bottomRadius: CGFloat, tint: Color, count: Int) {
        let now = Self.now
        for index in 0 ..< count {
            rings.append(Ring(
                born: now + Double(index) * Theme.Motion.Attention.ringGap,
                rect: silhouette(size),
                topRadius: topRadius,
                bottomRadius: bottomRadius,
                tint: tint
            ))
        }
        schedulePrune(after: Theme.Motion.Attention.ringLife + Double(count) * Theme.Motion.Attention.ringGap)
    }

    struct Rim {
        enum Mode { case pulse, sweep }
        let born: TimeInterval
        let life: TimeInterval
        let tint: Color
        let mode: Mode
        var end: TimeInterval { born + life }
    }

    func rim(_ tint: Color, mode: Rim.Mode) {
        let life = mode == .pulse ? Theme.Motion.Attention.rimPulse : Theme.Motion.Attention.rimSweep
        rims.append(Rim(born: Self.now, life: life, tint: tint, mode: mode))
        schedulePrune(after: life)
    }

    // MARK: The onboarding mascot

    /// The intro's mascot, drawn here rather than as a view so it can be built out of the very
    /// stars around it and come apart into pixels again without a seam between the two.
    struct BigMascot {
        var x: Track
        var y: Track
        var hop: Track
        let pixel: CGFloat
        let tint: Color
        let born: TimeInterval
        var flashAt: TimeInterval
        var status: SessionStatus = .waitingForInput
        var squint = false
        var followsPointer = false
        let seed = Double.random(in: 0 ..< 1000)

        func center(at t: TimeInterval) -> CGPoint {
            CGPoint(x: x.value(at: t), y: y.value(at: t) + hop.value(at: t))
        }

        /// The top-left of the 12x10 grid when the body is centred at `center`.
        func origin(at t: TimeInterval) -> CGPoint {
            let center = center(at: t)
            return CGPoint(
                x: center.x - CGFloat(AgentActivityGlyph.columns) * pixel / 2,
                y: center.y - CGFloat(AgentActivityGlyph.rows) * pixel / 2
            )
        }
    }

    /// The cells the mascot is made of at rest — what the stars gather into and what comes
    /// apart at the end.
    static var restingCells: [AgentActivityGlyph.Cell] {
        AgentActivityGlyph.cells(for: .waitingForInput, elapsed: 0)
    }

    func cellCenters(of cells: [AgentActivityGlyph.Cell], origin: CGPoint, pixel: CGFloat) -> [CGPoint] {
        cells.map {
            CGPoint(x: origin.x + (CGFloat($0.column) + 0.5) * pixel, y: origin.y + (CGFloat($0.row) + 0.5) * pixel)
        }
    }

    func hopBigMascot(_ height: CGFloat = 10) {
        guard var mascot = bigMascot else { return }
        let now = Self.now
        let liquid = Theme.Motion.Liquid.self
        mascot.hop.rebase(at: now)
        mascot.hop.retarget(-height, at: now, .bezier(liquid.decelerate, liquid.hopRise))
        mascot.hop.retarget(0, at: now + liquid.hopRise, .damped(liquid.hopLand))
        bigMascot = mascot
    }

    func flashBigMascot() {
        bigMascot?.flashAt = Self.now
    }

    // MARK: The lyric pill

    func showPill(line: String) {
        pill.show(line: line, under: attachment(collapsedSize, expanded: false), at: Self.now)
        pillActive = true
    }

    func setPillLine(_ line: String) {
        pill.setLine(line, at: Self.now)
    }

    func hidePill() {
        guard pillActive, pill.isShowing else { return }
        pill.hide(at: Self.now)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Theme.Motion.Liquid.pillLeave + 0.1))
            guard let self, !self.pill.isShowing else { return }
            pillActive = false
        }
    }

    // MARK: Housekeeping

    /// Clears out effects whose time is up. Scheduled by whatever spawned them, so the canvases
    /// stop ticking the moment nothing is moving.
    private func schedulePrune(after delay: TimeInterval) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay + 0.05))
            self?.prune()
        }
    }

    private func prune() {
        let now = Self.now
        drops.removeAll { $0.end <= now }
        stars.removeAll { $0.end <= now }
        pixels.removeAll { $0.end <= now }
        sparks.removeAll { $0.end <= now }
        rings.removeAll { $0.end <= now }
        rims.removeAll { $0.end <= now }
    }

    func clearDrops() {
        drops = []
    }

    // MARK: Drawing

    /// The metaball pass: every drop and the silhouettes they hang from, in solid black. The
    /// canvas this draws into blurs and thresholds the result.
    func drawLiquid(in context: inout GraphicsContext, at t: TimeInterval) {
        let black = GraphicsContext.Shading.color(Theme.Colors.surface)
        var attached: [Attachment] = []
        for drop in drops {
            if let notch = drop.attach, !attached.contains(notch) {
                attached.append(notch)
                context.fill(notch.path, with: black)
            }
            let r = drop.r.value(at: t)
            guard r > 0.2 else { continue }
            let center = CGPoint(x: drop.x.value(at: t), y: drop.y.value(at: t))
            context.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)), with: black)
        }
        guard pillActive else { return }
        if let notch = pill.attach(at: t), !attached.contains(notch) {
            context.fill(notch.path, with: black)
        }
        for blob in pill.blobs(at: t) where blob.radius > 0.2 {
            context.fill(
                Path(ellipseIn: CGRect(x: blob.center.x - blob.radius, y: blob.center.y - blob.radius, width: blob.radius * 2, height: blob.radius * 2)),
                with: black
            )
        }
    }

    /// Inside the silhouette: the star field, pixels in flight, and the onboarding mascot.
    func drawInner(in context: inout GraphicsContext, at t: TimeInterval) {
        for star in stars where t >= star.born {
            let live = t - star.born
            var alpha = min(1, live / 0.6) * star.opacity
            var size = star.size
            var tint = star.tint
            if let seek = star.seek, t > seek.start {
                let k = min(1, (t - seek.start) / (seek.response * 1.3))
                size = star.size + (seek.size - star.size) * CGFloat(k)
                alpha = 0.7 + 0.3 * k
                tint = k > 0.5 ? seek.tint : star.tint
            } else {
                alpha *= 0.45 + 0.55 * abs(sin(live * star.twinkle + star.phase))
            }
            if t > star.fadeAt { alpha *= max(0, 1 - (t - star.fadeAt) / 0.3) }
            guard alpha > 0.01 else { continue }
            let p = star.position(at: t)
            context.opacity = alpha
            context.fill(Path(CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)), with: .color(tint))
        }
        context.opacity = 1

        for pixel in pixels where t >= pixel.start {
            let u = min(1, (t - pixel.start) / pixel.duration)
            let head = point(on: pixel, at: u)
            let tail = point(on: pixel, at: max(0, u - 0.05))
            let eased = Track.glide(u)
            let size = pixel.shrinks
                ? pixel.size.upperBound - (pixel.size.upperBound - pixel.size.lowerBound) * eased
                : pixel.size.lowerBound + (pixel.size.upperBound - pixel.size.lowerBound) * eased
            var trail = Path()
            trail.move(to: tail)
            trail.addLine(to: head)
            context.opacity = 0.35
            context.stroke(trail, with: .color(pixel.tint), lineWidth: max(1, size * 0.6))
            context.opacity = 1
            context.fill(Path(CGRect(x: head.x - size / 2, y: head.y - size / 2, width: size, height: size)), with: .color(pixel.tint))
        }

        if let mascot = bigMascot, t >= mascot.born {
            drawBigMascot(mascot, in: &context, at: t)
        }
    }

    private func point(on pixel: Pixel, at u: Double) -> CGPoint {
        let p0 = pixel.from
        let p3 = resolve(pixel.to)
        let p1 = CGPoint(x: p0.x + pixel.lead.dx, y: p0.y + pixel.lead.dy)
        let p2 = CGPoint(x: p3.x + pixel.trail.dx, y: p3.y + pixel.trail.dy)
        let s = CGFloat(Track.glide(u))
        let v = 1 - s
        return CGPoint(
            x: v * v * v * p0.x + 3 * v * v * s * p1.x + 3 * v * s * s * p2.x + s * s * s * p3.x,
            y: v * v * v * p0.y + 3 * v * v * s * p1.y + 3 * v * s * s * p2.y + s * s * s * p3.y
        )
    }

    private func drawBigMascot(_ mascot: BigMascot, in context: inout GraphicsContext, at t: TimeInterval) {
        var glyphContext = AgentActivityGlyph.Context(seed: mascot.seed, headroom: AgentActivityGlyph.headroom)
        let center = mascot.center(at: t)
        if mascot.followsPointer, let pointer = pointer() {
            let dx = pointer.x - center.x
            let reach = Theme.Metrics.Agents.mascotGazeReach * 3
            glyphContext.gaze = AgentActivityGlyph.Gaze(dx: dx > reach ? 1 : dx < -reach ? -1 : 0, dy: 0)
        }
        var cells = AgentActivityGlyph.cells(
            for: mascot.status,
            elapsed: reduceMotion ? 0.25 : t - mascot.born,
            context: glyphContext
        )
        if mascot.squint {
            cells = AgentActivityGlyph.cells(for: .idle, elapsed: 0)
        }
        let flash = max(0, 1 - (t - mascot.flashAt) / 0.5)
        Self.drawGlyph(cells, in: &context, origin: mascot.origin(at: t), pixel: mascot.pixel, tint: mascot.tint, flash: flash)
    }

    /// The mascot's cells, shaded and bloomed the way `AgentActivityGlyphView` draws them.
    static func drawGlyph(
        _ cells: [AgentActivityGlyph.Cell],
        in context: inout GraphicsContext,
        origin: CGPoint,
        pixel: CGFloat,
        tint: Color,
        flash: Double = 0
    ) {
        let gap: CGFloat = pixel >= 2 ? 0.25 : 0
        func paint(_ layer: inout GraphicsContext) {
            for cell in cells {
                let rect = CGRect(
                    x: origin.x + CGFloat(cell.column) * pixel + gap,
                    y: origin.y + CGFloat(cell.row) * pixel + gap,
                    width: pixel - gap * 2,
                    height: pixel - gap * 2
                )
                let path = Path(rect)
                layer.opacity = cell.alpha
                switch cell.tone {
                case .body:
                    layer.fill(path, with: .color(tint))
                case .highlight:
                    layer.fill(path, with: .color(tint))
                    layer.opacity = cell.alpha * 0.42
                    layer.fill(path, with: .color(.white))
                case .shadow:
                    layer.fill(path, with: .color(tint))
                    layer.opacity = cell.alpha * 0.36
                    layer.fill(path, with: .color(.black))
                case .white:
                    layer.fill(path, with: .color(.white))
                case let .accent(color):
                    layer.fill(path, with: .color(color))
                }
                if flash > 0 {
                    layer.opacity = cell.alpha * flash
                    layer.fill(path, with: .color(.white))
                }
            }
        }
        context.drawLayer { bloom in
            bloom.addFilter(.blur(radius: pixel * 0.36))
            bloom.blendMode = .plusLighter
            bloom.opacity = 0.5
            paint(&bloom)
        }
        context.drawLayer { crisp in paint(&crisp) }
    }

    /// Outside the silhouette: rings, sparks, confetti and the lyric pill's words.
    func drawOuter(in context: inout GraphicsContext, at t: TimeInterval) {
        for ring in rings where t >= ring.born {
            let p = min(1, (t - ring.born) / Theme.Motion.Attention.ringLife)
            let grow = 4 + CGFloat(Track.decelerate(p)) * Theme.Motion.Attention.ringReach
            let rect = ring.rect.insetBy(dx: -grow, dy: 0)
            let path = Path(NotchShape.cgPath(
                in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + grow),
                topCornerRadius: ring.topRadius,
                bottomCornerRadius: ring.bottomRadius + grow / 2
            ))
            context.opacity = 0.85 * (1 - p)
            context.stroke(path, with: .color(ring.tint), lineWidth: Theme.Metrics.Attention.ringWidth * CGFloat(1 - p) + 0.6)
        }
        context.opacity = 1

        for spark in sparks where t >= spark.born {
            let fade = min(1, max(0, spark.end - t) / 0.35)
            guard fade > 0 else { continue }
            let p = spark.position(at: t)
            let width = spark.spin.map { spark.size * CGFloat(abs(cos((t - spark.born) * $0))) } ?? spark.size
            context.opacity = fade
            context.fill(Path(CGRect(x: p.x - width / 2, y: p.y - spark.size / 2, width: width, height: spark.size)), with: .color(spark.tint))
        }
        context.opacity = 1

        if pillActive { pill.drawText(in: &context, at: t) }
    }
}

// MARK: - Tracks

/// A value over time, as a chain of closed-form segments: each one starts from wherever the
/// chain had got to when it began, and eases or springs to its target.
///
/// `Animation` cannot be sampled, so the effects need their own. The springs use SwiftUI's
/// (response, damping) parameterisation so a token reads the same here as in `Theme.Motion`.
struct Track {
    enum Curve {
        /// Control points and a duration — see `Theme.Motion.Liquid` for the named ones.
        case bezier((Double, Double, Double, Double), TimeInterval)
        /// A spring from rest, as (response, damping fraction).
        case damped((response: Double, damping: Double))
    }

    private struct Segment {
        let start: TimeInterval
        let target: CGFloat
        let curve: Curve
    }

    private var initial: CGFloat
    private var segments: [Segment] = []

    init(_ value: CGFloat) {
        initial = value
    }

    /// Adds a segment. A segment that starts before the last one would make the chain ambiguous,
    /// so starts are clamped to stay in order.
    mutating func retarget(_ target: CGFloat, at start: TimeInterval, _ curve: Curve) {
        let start = max(start, segments.last?.start ?? start)
        segments.append(Segment(start: start, target: target, curve: curve))
    }

    /// Forgets everything before `t`, so a value retargeted at every lyric line does not grow a
    /// history.
    mutating func rebase(at t: TimeInterval) {
        guard segments.count > 1, let last = segments.last, t >= last.start else { return }
        let current = value(at: last.start, through: segments.count - 1)
        initial = current
        segments = [last]
    }

    func value(at t: TimeInterval) -> CGFloat {
        value(at: t, through: segments.count)
    }

    private func value(at t: TimeInterval, through count: Int) -> CGFloat {
        var result = initial
        for index in 0 ..< count {
            let segment = segments[index]
            guard t >= segment.start else { break }
            let from = index == 0 ? initial : value(at: segment.start, through: index)
            result = Self.sample(segment.curve, from: from, to: segment.target, elapsed: t - segment.start)
        }
        return result
    }

    private static func sample(_ curve: Curve, from: CGFloat, to: CGFloat, elapsed: TimeInterval) -> CGFloat {
        switch curve {
        case let .bezier(points, duration):
            let p = duration > 0 ? min(1, elapsed / duration) : 1
            return from + (to - from) * CGFloat(UnitBezier(points).solve(p))
        case let .damped(spring):
            return damped(from: from, to: to, spring: spring, elapsed: elapsed)
        }
    }

    /// A spring released from rest at `from`, solved exactly. Over-damping is clamped to
    /// critical: nothing here wants a slower-than-critical settle.
    static func damped(from: CGFloat, to: CGFloat, spring: (response: Double, damping: Double), elapsed t: TimeInterval) -> CGFloat {
        let omega = 2 * Double.pi / max(spring.response, 0.001)
        let zeta = min(max(spring.damping, 0), 1)
        let displacement = Double(from - to)
        let offset: Double
        if zeta > 0.999 {
            offset = displacement * (1 + omega * t) * exp(-omega * t)
        } else {
            let omegaD = omega * (1 - zeta * zeta).squareRoot()
            offset = exp(-zeta * omega * t) * (displacement * cos(omegaD * t) + (zeta * omega * displacement / omegaD) * sin(omegaD * t))
        }
        return to + CGFloat(offset)
    }

    static func glide(_ p: Double) -> Double { UnitBezier(Theme.Motion.Liquid.glide).solve(p) }
    static func decelerate(_ p: Double) -> Double { UnitBezier(Theme.Motion.Liquid.decelerate).solve(p) }
}

/// A CSS-style cubic timing curve, solved for y at a given x.
struct UnitBezier {
    private let cx, bx, ax, cy, by, ay: Double

    init(_ points: (Double, Double, Double, Double)) {
        cx = 3 * points.0
        bx = 3 * (points.2 - points.0) - cx
        ax = 1 - cx - bx
        cy = 3 * points.1
        by = 3 * (points.3 - points.1) - cy
        ay = 1 - cy - by
    }

    func solve(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        var t = x
        for _ in 0 ..< 8 {
            let dx = ((ax * t + bx) * t + cx) * t - x
            let slope = (3 * ax * t + 2 * bx) * t + cx
            guard abs(slope) > 1e-6 else { break }
            t = min(max(t - dx / slope, 0), 1)
        }
        return ((ay * t + by) * t + cy) * t
    }
}

// MARK: - Mascot anchors

extension View {
    /// Reports where this mascot is drawn, so pixels can fly to and from it, and hides it while
    /// its pixels are in the air.
    func mascotAnchor(_ role: NotchFX.MascotRole) -> some View {
        modifier(MascotAnchorModifier(role: role))
    }
}

private struct MascotAnchorModifier: ViewModifier {
    let role: NotchFX.MascotRole
    @Environment(NotchFX.self) private var fx: NotchFX?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(NotchFX.space)) } action: { frame in
                fx?.anchors[role] = frame
            }
            .onDisappear { fx?.anchors[role] = nil }
            .opacity(fx?.hidden.contains(role) == true ? 0 : 1)
    }
}
