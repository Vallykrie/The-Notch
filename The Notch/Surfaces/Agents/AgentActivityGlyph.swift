import SwiftUI

/// The mascot: one small pixel blob, doing whatever the agent is doing — and noticing things.
///
/// The panel is about several agents working on your behalf, and it wanted a character in it
/// rather than nine icons taking turns. Several designs went in the bin getting here — nine
/// unrelated abstract glyphs, a robot, four rounds of crab — and the useful lesson is not about
/// any of them individually. It is that at twelve cells across, **anatomy is a liability**. A
/// crab has to get claws and eyestalks right or it reads as a bug; a robot has to get a neck and
/// arms right or it reads as a bottle. A blob has no anatomy to get wrong, so every cell the
/// grid has goes into the things that actually read at this size.
///
/// The body is **low and wide, in every state**. It never stretches tall and never thins out —
/// the silhouette is a constant, and an earlier version that squashed and stretched it was
/// wrong for the same reason nine unrelated glyphs were wrong: a shape that changes is a
/// different *thing*, not the same thing behaving differently. Only `compacting` alters it, by
/// a single row, because there the compression is the message.
///
/// So the state is carried by three appendage channels instead:
///
/// | State              | Antennae        | Eyes             | Body               |
/// | ------------------ | --------------- | ---------------- | ------------------ |
/// | `working`          | drag, catch up  | open, blinking   | 4-frame bob, legs  |
/// | `thinking`         | asymmetric sway | drifting sideways| still              |
/// | `runningTool`      | folded flat     | narrowed         | legs going fast    |
/// | `compacting`       | folded          | narrowed         | a row flatter      |
/// | `needsApproval`    | both up         | wide on the beat | hops on the beat   |
/// | `waitingForAnswer` | one up, one flat| open             | leaning            |
/// | `waitingForInput`  | mid             | blinking         | still              |
/// | `done`             | wagging         | narrowed         | two hops, then still|
/// | `idle`             | folded          | slits            | still, then asleep |
///
/// **The art is an arcade invader sprite.** One saturated colour per state, eyes that are
/// *holes* so the black surface shows through, and character from appendages rather than from
/// internal detail. The colour is shaded the way a finished console sprite is — a lit top edge
/// and a shadowed underside, both derived from the one status hue — so the blob has volume
/// without the dim-mass-with-bright-highlights look that made two earlier mascots read as clay.
///
/// **It is alive, not just animated.** Four layers sit on top of the state loops:
///
/// - *Reactions.* Entering a state from another plays a short one-shot first: a startle and a
///   shake when approval is needed, a glance up when thinking starts, legs revving before work,
///   a second victory hop when done. Only on a real transition this view saw — a row that
///   scrolls into view does not re-react to a state it has been in for an hour.
/// - *Personality.* In the calm states it fidgets: looks around, double-blinks, twitches an
///   antenna, hops in place. Seeded per view, so four idle rows never fidget in unison.
/// - *Attention.* In the expanded panel its eyes follow the pointer while it is calm.
/// - *Sleep.* A long-idle session closes its eyes, breathes, and snores.
///
/// Cells are separated by a hairline gap so the pixel grid is visible, with a bloom pass
/// underneath so lit cells glow the way phosphor does. The notch's black surface is the one
/// place in macOS where a CRT idiom is literally correct rather than a skeuomorphic affectation.
///
/// Positions are quantised to the pixel grid; only alpha is continuous. A mark that slid by
/// fractions of a point at these sizes is a smudge that changes shape, not a movement.
@MainActor
struct AgentActivityGlyph {
    /// How a lit cell is coloured. Everything except `accent` is derived from the view's
    /// foreground style, so the status hue stays the one source of colour.
    enum Tone: Equatable {
        case body
        /// The lit top edge: the hue lifted toward white.
        case highlight
        /// The underside and legs: the hue pushed toward black.
        case shadow
        /// Glints, sparkles and the startle mark.
        case white
        /// A colour of its own. Only the confetti, which is the one place the mascot celebrates
        /// in more than its own hue.
        case accent(Color)
    }

    /// One lit cell of the grid.
    struct Cell: Equatable {
        let column: Int
        let row: Int
        let alpha: Double
        var tone: Tone = .body
    }

    /// Where the pointer is relative to the mascot, in whole cells of eye travel.
    struct Gaze: Equatable {
        let dx: Int
        let dy: Int
    }

    /// Everything besides the state and the time that a frame depends on.
    struct Context {
        /// Phases blinks and fidgets, so marks side by side never act in unison.
        var seed = 0.0
        /// The state this view saw before the current one. `nil` means the state was already
        /// in effect when the view appeared, which is exactly when no reaction should play.
        var previous: SessionStatus?
        var gaze: Gaze?
        /// Rows above the grid the mark may draw into. See `headroom`.
        var headroom = 0
        /// Whether the small pixel effects around the body draw at all.
        var effects = false
        var asleep = false
        /// Seconds since a brand-new session's mark first appeared, while it is arriving.
        var arrival: Double?
    }

    /// 12 columns by 10 rows, which at the panel's 30pt is a 3pt cell.
    ///
    /// Grid size and apparent pixel size trade directly against each other at a fixed on-screen
    /// size, and this mark is pixel art before it is anything else. A 16-column grid in the same
    /// row is a 2pt cell — four device pixels — which stops reading as a block and starts
    /// reading as a small smooth icon.
    ///
    /// Ten rows rather than twelve because the creature is wider than it is tall and the grid
    /// should not be paying for empty space above its head. It also means the *whole* figure
    /// fits the collapsed shoulder at a visible 2pt cell, so there is no cropped variant to keep
    /// in sync with the full one.
    static let columns = 12
    static let rows = 10

    /// Rows the expanded mark may draw *above* its layout frame.
    ///
    /// Without it, every hop fought the top of the grid: a raised antenna on a lifted body left
    /// the grid and was deleted, so the mark lost its antennae instead of jumping, and several
    /// states had to hold still on exactly the beat that wanted movement. Two rows of overflow
    /// let the approval heartbeat hop, let the sleeping blob's Z's rise, and cost no layout —
    /// the row still measures ten rows.
    ///
    /// The collapsed shoulder gets none: there is no room above the notch, and a mark that drew
    /// past the hardware edge would be clipped by the bezel. There, lifts are capped instead
    /// (see `render`), so an antenna shortens on the up-beat rather than vanishing.
    static let headroom = 2

    /// The lit cells for a state, `elapsed` seconds after it was entered.
    ///
    /// Driven by time-since-entry rather than by absolute time, deliberately. Absolute time puts
    /// every mascot in the panel in lockstep, and four blobs blinking in perfect unison reads as
    /// one animation drawn four times — as chrome. Phased from when each session actually
    /// entered its state, the same four read as four independent things working.
    static func cells(for status: SessionStatus, elapsed: Double, context: Context = Context()) -> [Cell] {
        var cells = render(pose(for: status, elapsed: elapsed, context: context), headroom: context.headroom)
        if context.effects {
            cells += effects(for: status, elapsed: elapsed, context: context)
        }
        if let arrival = context.arrival {
            cells = arrive(cells, elapsed: arrival, headroom: context.headroom)
        }
        return cells.filter {
            (0 ..< columns).contains($0.column) && (-context.headroom ..< rows).contains($0.row)
        }
    }

    // MARK: The poses

    private static func pose(for status: SessionStatus, elapsed: Double, context: Context) -> Pose {
        var pose: Pose = switch status {
        case .working: working(elapsed)
        case .thinking: thinking(elapsed)
        case .runningTool: runningTool(elapsed)
        case .compacting: compacting(elapsed)
        case .needsApproval: needsApproval(elapsed, canHop: context.headroom > 0)
        case .waitingForAnswer: waitingForAnswer(elapsed)
        case .waitingForInput: waitingForInput(elapsed)
        case .done: done(elapsed)
        case .idle: idle(elapsed)
        }

        if blinks(status), pose.eyes == .open, blink(at: elapsed, seed: context.seed) {
            pose.eyes = .closed
        }
        let reacting = context.previous != nil
        if reacting {
            react(&pose, to: status, elapsed: elapsed)
        }
        if status == .idle, context.asleep {
            sleep(&pose, elapsed: elapsed)
            return pose
        }
        if fidgets(status), elapsed > Timing.settle {
            fidget(&pose, elapsed: elapsed, seed: context.seed)
        }
        if notices(status), let gaze = context.gaze, !(reacting && elapsed < Timing.reaction) {
            // Slits open to look at you — the one time an idle blob's eyes are fully open.
            if pose.eyes == .narrow || pose.eyes == .closed { pose.eyes = .open }
            pose.eyeShift = gaze.dx
            pose.eyeLift = gaze.dy
        }
        return pose
    }

    // MARK: Busy

    /// Bobbing along with its legs shuffling and its antennae flicking.
    ///
    /// Four frames, not two: rest, rise, apex, land. The antennae *drag* on the rise and catch
    /// up at the apex — follow-through, the one thing that stops a bob reading as a rigid
    /// object being moved up and down. A two-frame toggle has nowhere to put it.
    ///
    /// The bob goes *up* from rest, never down. In the collapsed shoulder there is no headroom,
    /// and `render` caps the antennae on exactly the frames the body rises.
    private static func working(_ elapsed: Double) -> Pose {
        let step = Int(phase(elapsed, Theme.Motion.AgentActivity.working) * 4) % 4

        var pose = Pose()
        pose.bob = [0, -1, -1, 0][step]
        pose.legPhase = step % 2
        pose.antennaLeft = [2, 1, 2, 2][step]
        pose.antennaRight = pose.antennaLeft
        return pose
    }

    /// Still, eyes drifting side to side, antennae swaying out of step.
    ///
    /// Eyes that wander off-centre and come back are the one thing a face can do that
    /// unambiguously means *not currently addressing you*, and here it costs one cell of travel.
    /// The antennae sway in opposition rather than together — symmetric movement reads as the
    /// whole creature moving, asymmetric movement reads as it idling.
    private static func thinking(_ elapsed: Double) -> Pose {
        let wave = sin(2 * .pi * phase(elapsed, Theme.Motion.AgentActivity.thinking))

        var pose = Pose()
        pose.eyeShift = Int((wave * 1.3).rounded())
        pose.antennaLeft = wave > 0 ? 2 : 1
        pose.antennaRight = wave > 0 ? 1 : 2
        return pose
    }

    /// Legs going fast, eyes narrowed, antennae flat to the body.
    ///
    /// The same walk cycle as `working` at four times the rate, which is the cheapest possible
    /// way to say *the same thing, harder*. Flattened antennae and narrowed eyes are the
    /// concentration: everything pulled in tight.
    private static func runningTool(_ elapsed: Double) -> Pose {
        var pose = Pose()
        pose.legPhase = Int(phase(elapsed, Theme.Motion.AgentActivity.tool) * 8) % 2
        pose.eyes = .narrow
        pose.antennaLeft = 0
        pose.antennaRight = 0
        return pose
    }

    /// Squashing a row flatter, holding, then springing back.
    ///
    /// The one state that touches the silhouette, because here the compression *is* the message
    /// — it is literally what the agent is doing to its context window. One row, not three: this
    /// body is already low, and flattening it far enough to be dramatic turns it into a puddle
    /// that no longer reads as the same creature.
    private static func compacting(_ elapsed: Double) -> Pose {
        let phase = phase(elapsed, Theme.Motion.AgentActivity.compacting)
        let squeeze = min(1, phase / 0.75)
        let eased = squeeze * squeeze * (3 - 2 * squeeze)

        var pose = Pose()
        pose.squashed = eased > 0.55
        pose.eyes = .narrow
        pose.antennaLeft = 0
        pose.antennaRight = 0
        // Dimming through the hold is what stops the held frame reading as the animation having
        // stalled — something has to still be changing while the shape is not.
        pose.brightness = 1 - max(0, (phase - 0.75) / 0.25) * 0.25
        return pose
    }

    // MARK: Blocked on the user

    /// Antennae up, eyes widening and the body hopping on a double heartbeat.
    ///
    /// Two beats and a rest, not an even pulse. An evenly pulsing mark is ambient — it is what
    /// every busy indicator in every app does, and the eye stops seeing it within a minute. A
    /// heartbeat has a rhythm peripheral vision keeps noticing, which is the entire job of the
    /// one state where an agent is stopped dead waiting for a person.
    ///
    /// The hop only happens where there is headroom for it. With both antennae fully raised, a
    /// lift in the collapsed shoulder would have to shorten them on every beat, and a mark whose
    /// antennae flicker in length is changing shape, not jumping.
    private static func needsApproval(_ elapsed: Double, canHop: Bool) -> Pose {
        let beat = heartbeat(elapsed)

        var pose = Pose()
        pose.antennaLeft = 2
        pose.antennaRight = 2
        pose.bob = canHop && beat > 0.6 ? -1 : 0
        // The eyes widen *on* the beat rather than staying wide. Held wide they are simply two
        // bigger holes; widening with the pulse makes the same cells read as a reaction.
        pose.eyes = beat > 0.45 ? .wide : .open
        // A wide swing, because brightness is the other channel carrying the beat.
        pose.brightness = 0.5 + 0.5 * beat
        return pose
    }

    /// Leaning, one antenna up and one folded — the shape of someone asking a question.
    ///
    /// The lean moves the whole upper body as a single block rather than shearing it row by row.
    /// A per-row shear tears the antennae apart: a diagonal whose rows each shift by a different
    /// rounded amount is no longer a connected line.
    private static func waitingForAnswer(_ elapsed: Double) -> Pose {
        let wave = sin(2 * .pi * phase(elapsed, Theme.Motion.AgentActivity.question))

        var pose = Pose()
        pose.lean = wave > 0 ? 1 : 0
        pose.antennaLeft = 0
        pose.antennaRight = 2
        // The eyes track the lean instead of staying level, which is the difference between a
        // blob leaning and a blob being pushed.
        pose.eyeShift = pose.lean
        return pose
    }

    /// Still, eyes blinking at a terminal's cadence.
    ///
    /// This state means the turn ended and the next move is yours, and a blinking cursor is the
    /// one mark in computing that says exactly that. It is a hard on/off rather than a fade: the
    /// eyes are holes, and a hole cannot be drawn at half strength.
    private static func waitingForInput(_ elapsed: Double) -> Pose {
        var pose = Pose()
        pose.eyes = phase(elapsed, Theme.Motion.AgentActivity.cursor) < 0.5 ? .open : .closed
        return pose
    }

    // MARK: Finished, and not started

    /// One hop, then a contented wag of the antennae.
    ///
    /// A *frozen* finished row does not read as finished — it reads as stalled, or as a mark
    /// that has stopped updating. So the distinction is carried by the kind of motion rather
    /// than its absence: the wag is slower than any busy state, moves only the antennae, and the
    /// body stays dimmed at `doneRestAlpha`. It says the creature is sitting there pleased with
    /// itself, which is exactly the state.
    private static func done(_ elapsed: Double) -> Pose {
        let hop = ramp(elapsed / Theme.Motion.AgentActivity.doneDraw)
            - ramp((elapsed - Theme.Motion.AgentActivity.doneDraw - 0.2) / 0.25)
        let airborne = hop > 0.4
        let wag = sin(2 * .pi * phase(elapsed, Theme.Motion.AgentActivity.doneWag)) > 0

        var pose = Pose()
        pose.bob = airborne ? -1 : 0
        pose.antennaLeft = airborne ? 1 : (wag ? 2 : 1)
        pose.antennaRight = airborne ? 1 : (wag ? 1 : 2)
        pose.eyes = .narrow
        pose.brightness = Figure.doneRestAlpha + (1 - Figure.doneRestAlpha) * hop
        return pose
    }

    /// Sitting there with its eyes half shut. Barely an animation, which is correct — an idle
    /// session that draws the eye is a session misreporting itself. The rare blink is there
    /// because a figure that never moves at all is indistinguishable from one that has crashed.
    ///
    /// Slits rather than a full blink at rest. With hole-eyes, "closed" means no eyes at all,
    /// and a blank face at rest reads as a rendering fault rather than as sleeping.
    private static func idle(_ elapsed: Double) -> Pose {
        var pose = Pose()
        pose.eyes = phase(elapsed, Theme.Motion.AgentActivity.idle) > 0.96 ? .closed : .narrow
        pose.antennaLeft = 0
        pose.antennaRight = 0
        pose.brightness = 0.9
        return pose
    }

    // MARK: Being alive

    /// The one-shot a state plays when this view watched it begin.
    ///
    /// Each is under a second and each says *how* the state arrived, which the loop that follows
    /// cannot: approval is a surprise, so it startles; thinking is a turn inward, so it glances
    /// up; work is a start, so the legs rev before the walk settles.
    private static func react(_ pose: inout Pose, to status: SessionStatus, elapsed e: Double) {
        let timing = Theme.Motion.AgentActivity.self
        switch status {
        case .needsApproval:
            if e < timing.startleJump {
                pose.bob = -1
                pose.eyes = .wide
                pose.antennaLeft = 2
                pose.antennaRight = 2
                pose.brightness = 1
            } else if e < timing.startleShake {
                // One cell either way at 30Hz: the shiver of something that got a fright.
                pose.shift = Int(e * 30) % 2 == 0 ? 1 : -1
                pose.eyes = .wide
                pose.brightness = 1
            }
        case .thinking where e < Timing.reaction:
            pose.eyeLift = -1
            pose.eyeShift = 1
            pose.antennaLeft = 2
            pose.antennaRight = 2
        case .working where e < timing.revUp:
            pose.bob = 0
            pose.legPhase = Int(e * 22) % 2
            pose.antennaLeft = 0
            pose.antennaRight = 0
            pose.eyes = .narrow
        case .waitingForAnswer where e < Timing.reaction:
            pose.lean = 1
            pose.antennaLeft = 0
            pose.antennaRight = 2
            pose.eyeShift = 1
            pose.eyeLift = -1
        case .compacting where e < timing.revUp:
            pose.squashed = true
            pose.eyes = .closed
        case .waitingForInput where e < timing.revUp:
            // Turns to face you: a blink, then eyes front with antennae up.
            pose.eyeShift = 0
            pose.eyes = e < Timing.blinkLength ? .closed : .open
            pose.antennaLeft = 2
            pose.antennaRight = 2
        case .done:
            let second = ramp((e - timing.secondHop) / 0.18) - ramp((e - timing.secondHop - 0.3) / 0.18)
            if second > 0.4 {
                pose.bob = -1
                pose.antennaLeft = 2
                pose.antennaRight = 2
            }
        default:
            break
        }
    }

    /// Something small, every few seconds, while there is nothing to do.
    ///
    /// Five gestures, picked and placed per window from the seed, so the rhythm never repeats
    /// and two rows never fidget together. Each lasts about a second; most of every window is
    /// the state's own loop, so the fidget is punctuation rather than a second animation.
    private static func fidget(_ pose: inout Pose, elapsed e: Double, seed: Double) {
        let window = Theme.Motion.AgentActivity.fidgetWindow
        let index = (e / window).rounded(.down)
        let offset = hash(index * 7.7 + seed) * 2 + 0.6
        let t = e - index * window - offset
        guard t > 0, t < Theme.Motion.AgentActivity.fidgetLength else { return }

        switch Int(hash(index * 3.1 + seed) * 5) {
        case 0:
            // Looks left, then right.
            if pose.eyes == .closed { pose.eyes = .open }
            pose.eyeShift = t < 0.5 ? -1 : 1
        case 1:
            pose.eyes = .open
            pose.eyeLift = -1
        case 2:
            if t < 0.1 || (t > 0.22 && t < 0.32) { pose.eyes = .closed }
        case 3:
            pose.antennaLeft = t < 0.3 ? 2 : t < 0.6 ? 0 : 2
        default:
            if t < 0.22 {
                pose.bob = -1
                pose.antennaLeft = 1
                pose.antennaRight = 1
            }
        }
    }

    /// Eyes shut low, antennae down, and a slow breath in the brightness.
    ///
    /// The eyes are drawn one row *lower* rather than removed: a blob with no eyes at all reads
    /// as a rendering fault, and a pair of low lines reads as lids.
    private static func sleep(_ pose: inout Pose, elapsed e: Double) {
        pose.eyes = .asleep
        pose.eyeShift = 0
        pose.eyeLift = 0
        pose.antennaLeft = 0
        pose.antennaRight = 0
        pose.brightness = 0.72 + 0.14 * sin(2 * .pi * phase(e, Theme.Motion.AgentActivity.breath))
    }

    private static func blinks(_ status: SessionStatus) -> Bool {
        switch status {
        case .working, .thinking, .waitingForAnswer: true
        default: false
        }
    }

    /// The states with nothing to do, where fidgeting reads as personality. Never a busy state
    /// — a fidget there would read as the agent being distracted — and never approval, which
    /// must hold still enough to stay urgent.
    private static func fidgets(_ status: SessionStatus) -> Bool {
        switch status {
        case .waitingForInput, .idle, .done, .waitingForAnswer: true
        default: false
        }
    }

    /// The states in which it looks at the pointer. Approval included: a blob stopped dead on
    /// you is the one that should most obviously be looking at you.
    private static func notices(_ status: SessionStatus) -> Bool {
        fidgets(status) || status == .needsApproval
    }

    private static func blink(at e: Double, seed: Double) -> Bool {
        let window = Theme.Motion.AgentActivity.blinkWindow
        let index = (e / window).rounded(.down)
        let t = e - index * window - (0.4 + hash(index * 13.7 + seed) * 2.5)
        return t >= 0 && t < Timing.blinkLength
    }

    // MARK: Effects

    /// Small pixel effects around the body. Expanded panel only, and deliberately few: a
    /// startle mark, a celebration, and snoring. Everything else the blob says with its body.
    private static func effects(for status: SessionStatus, elapsed e: Double, context: Context) -> [Cell] {
        let timing = Theme.Motion.AgentActivity.self
        var cells: [Cell] = []
        switch status {
        case .needsApproval:
            if context.previous != nil, e < timing.startleMark {
                // A flashing "!" beside the head for the first moments, then only its dot,
                // lit on the heartbeat.
                let alpha = min(1, (timing.startleMark - e) / 0.4)
                let tone: Tone = Int(e * 10) % 2 == 0 ? .white : .highlight
                for row in [0, 1, 2, 4] {
                    cells.append(Cell(column: Figure.markColumn, row: row, alpha: alpha, tone: tone))
                }
            } else {
                let beat = heartbeat(e)
                if beat > 0.4 {
                    cells.append(Cell(column: Figure.markColumn, row: 4, alpha: beat, tone: .highlight))
                }
            }
        case .done:
            if context.previous != nil {
                cells += confetti(e - timing.confettiDelay)
            }
            cells += twinkle(e, seed: context.seed)
        case .idle where context.asleep:
            cells += snore(e)
        default:
            break
        }
        return cells
    }

    /// A burst of every status colour, falling. The one time the mascot leaves its own hue.
    private static func confetti(_ t: Double) -> [Cell] {
        let life = Theme.Motion.AgentActivity.confettiLife
        guard t >= 0, t < life else { return [] }
        let palette: [Tone] = [
            .accent(Theme.Colors.Status.done), .accent(Theme.Colors.Status.needsApproval),
            .accent(Theme.Colors.Status.working), .accent(Theme.Colors.Status.thinking),
            .accent(Theme.Colors.Status.question), .white,
        ]
        return (0 ..< 12).map { index in
            let i = Double(index)
            let vx = (hash(i + 0.3) - 0.5) * 16
            let vy = -9 - hash(i + 9.1) * 9
            return Cell(
                column: Int((5.5 + vx * t).rounded()),
                row: Int((1 + vy * t + 15 * t * t).rounded()),
                alpha: 1 - t / life,
                tone: palette[index % palette.count]
            )
        }
    }

    /// Now and then a small sparkle near the head of a finished blob.
    private static func twinkle(_ e: Double, seed: Double) -> [Cell] {
        let period = Theme.Motion.AgentActivity.twinkle
        guard e >= Theme.Motion.AgentActivity.twinkleAfter else { return [] }
        let index = (e / period).rounded(.down)
        let t = e - index * period
        guard t < 0.35 else { return [] }

        let column = Int((hash(index + seed) * 11).rounded())
        let row = Int((hash(index * 3 + seed) * 2).rounded()) - 1
        var cells = [Cell(column: column, row: row, alpha: 1 - t / 0.35, tone: .white)]
        if t > 0.06, t < 0.26 {
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                cells.append(Cell(column: column + dx, row: row + dy, alpha: 0.7, tone: .highlight))
            }
        }
        return cells
    }

    /// Two small Z's rising and fading, out of step.
    private static func snore(_ e: Double) -> [Cell] {
        let period = Theme.Motion.AgentActivity.snore
        return (0 ..< 2).flatMap { index -> [Cell] in
            let age = phase(e - Double(index) * period / 2, period) * period
            let alpha = sin(.pi * age / period) * 0.8
            let column = 8 + Int((age * 0.5).rounded())
            let row = Int((1 - age * 1.2).rounded())
            return Figure.z.map { Cell(column: column + $0.0, row: row + $0.1, alpha: alpha, tone: .highlight) }
        }
    }

    /// A brand-new session beams in: a column of light, and the body revealed bottom-up.
    private static func arrive(_ cells: [Cell], elapsed e: Double, headroom: Int) -> [Cell] {
        let length = Theme.Motion.AgentActivity.arrival
        guard e < length else { return cells }
        let reveal = Double(rows) - e / (length * 0.7) * Double(rows + headroom)
        let settled = ramp(e / (length * 0.85)) > 0.5
        var shown = cells.filter { Double($0.row) >= reveal }.map { cell in
            settled ? cell : Cell(column: cell.column, row: cell.row, alpha: cell.alpha, tone: .white)
        }
        for row in -headroom ..< rows {
            let alpha = 0.55 * (1 - e / length) * (Double(row) >= reveal - 1 ? 1 : 0.4)
            shown.append(Cell(column: 5, row: row, alpha: alpha, tone: .white))
            shown.append(Cell(column: 6, row: row, alpha: alpha, tone: .white))
        }
        return shown
    }

    // MARK: Drawing

    /// How the blob is sitting at one instant. Everything a state can change is here, so the
    /// state functions stay declarative and only `render` knows the artwork.
    private struct Pose {
        /// The one row of compression `compacting` uses. Nothing else touches the silhouette.
        var squashed = false
        /// Whole-body vertical offset, in cells. Negative is up; positive would leave the grid.
        var bob = 0
        /// Whole-upper-body sideways offset, in cells, with the legs left planted.
        var lean = 0
        /// Whole-body sideways offset, legs included. Only the startle shake uses it.
        var shift = 0
        /// Which of the two leg frames to draw — the shuffle.
        var legPhase = 0
        /// Antennae, folded (0) to fully raised (2).
        var antennaLeft = 1
        var antennaRight = 1
        var eyes = Eyes.open
        /// Sideways gaze, in cells.
        var eyeShift = 0
        /// Vertical gaze, in cells. Negative looks up.
        var eyeLift = 0
        /// Multiplies every cell. Used by the states whose whole body is the signal.
        var brightness = 1.0
    }

    /// The eyes are holes punched out of the body, so these describe how much gets removed.
    private enum Eyes {
        /// Two cells each — the resting eye.
        case open
        /// Two cells each, over two rows, with a glint in the corner. Reads as alarm.
        case wide
        /// One cell each: narrowed at work, or half shut when idle.
        case narrow
        /// Nothing punched at all.
        case closed
        /// Two cells each, a row low: lids.
        case asleep
    }

    private enum Part {
        case body, antenna, tip, leg
    }

    private static func render(_ pose: Pose, headroom: Int) -> [Cell] {
        let art = pose.squashed ? Art.squashed : Art.rest
        var parts: [Point: Part] = [:]

        for (row, columns) in art.body {
            for column in columns { parts[Point(column, row)] = .body }
        }
        // Capped so the tip never leaves the drawable area. A lift that cannot fit shortens the
        // antenna by a cell instead of deleting it — a lost antenna is a shape change, a
        // shorter one is still the same creature reaching up.
        let reach = art.antennaRow + pose.bob + headroom
        antenna(into: &parts, root: Art.leftAntennaColumn, direction: -1, row: art.antennaRow, lift: min(pose.antennaLeft, reach))
        antenna(into: &parts, root: Art.rightAntennaColumn, direction: 1, row: art.antennaRow, lift: min(pose.antennaRight, reach))
        for leg in Art.legs(phase: pose.legPhase) { parts[Point(leg.0, leg.1)] = .leg }

        let (holes, glints) = eyeHoles(pose, art: art)
        for hole in holes { parts[hole] = nil }

        func place(_ point: Point) -> Point {
            // The lean moves everything above the legs as one block. Per-row shearing tears the
            // antennae apart — a diagonal whose rows shift by different rounded amounts stops
            // being a connected line.
            Point(point.column + (point.row <= Art.bodyFloorRow ? pose.lean : 0) + pose.shift, point.row + pose.bob)
        }

        let placed = parts.map { (place($0.key), $0.value) }
        let occupied = Set(placed.map(\.0))
        var cells = placed.map { point, part -> Cell in
            let tone: Tone = if part == .leg {
                .shadow
            } else if part == .tip || !occupied.contains(Point(point.column, point.row - 1)) {
                .highlight
            } else if !occupied.contains(Point(point.column, point.row + 1)) {
                .shadow
            } else {
                .body
            }
            return Cell(column: point.column, row: point.row, alpha: pose.brightness, tone: tone)
        }
        for glint in glints {
            let point = place(glint)
            cells.append(Cell(column: point.column, row: point.row, alpha: 1, tone: .white))
        }
        return cells
    }

    /// A connected diagonal run out from the shoulder. At lift zero it folds flat against the
    /// body instead of vanishing, so the creature never loses its outline.
    private static func antenna(
        into parts: inout [Point: Part],
        root: Int,
        direction: Int,
        row: Int,
        lift: Int
    ) {
        parts[Point(root, row)] = .antenna
        guard lift > 0 else {
            parts[Point(root + direction, row)] = .antenna
            return
        }
        let reach = min(lift, Art.maxAntennaLift)
        for step in 1 ... reach {
            parts[Point(root + direction * step, row - step)] = step == reach ? .tip : .antenna
        }
    }

    /// Which cells to punch out for the eyes, and where a wide eye catches the light.
    private static func eyeHoles(_ pose: Pose, art: Art.Frame) -> (holes: [Point], glints: [Point]) {
        guard pose.eyes != .closed else { return ([], []) }
        let row = art.eyeRow + (pose.eyes == .asleep ? 1 : pose.eyeLift)
        guard let span = art.body.first(where: { $0.row == row })?.columns else { return ([], []) }

        let rows = pose.eyes == .wide ? [row, row - 1] : [row]
        let shift = pose.eyes == .asleep ? 0 : pose.eyeShift
        var holes: [Point] = []
        var glints: [Point] = []
        for start in Art.eyeColumns {
            let width = pose.eyes == .narrow ? 1 : 2
            for offset in 0 ..< width {
                // Clamped to leave a body cell either side. An eye that reaches the outermost
                // column stops being an eye and becomes a bite out of the silhouette.
                let column = min(max(start + offset + shift, span.lowerBound + 1), span.upperBound - 2)
                for eyeRow in rows { holes.append(Point(column, eyeRow)) }
                if pose.eyes == .wide, offset == 0 { glints.append(Point(column, row - 1)) }
            }
        }
        return (holes, glints)
    }

    private struct Point: Hashable {
        let column: Int
        let row: Int
        init(_ column: Int, _ row: Int) {
            self.column = column
            self.row = row
        }
    }

    /// The blob, as coordinates.
    ///
    /// ```
    ///  . . # . . . . . . # . .   antennae, raised
    ///  . . . # . . . . # . . .
    ///  . . . . # # # # . . . .   body
    ///  . . # # # # # # # # . .
    ///  . # # . . # # . . # # .   eyes, punched out
    ///  . # # # # # # # # # # .
    ///  . . # # # # # # # # . .
    ///  . . . # # . . # # . . .   legs
    ///  . . # . . . . . . # . .
    /// ```
    ///
    /// Low and wide in every state. The proportion is the one thing about this mascot that does
    /// not vary, and that is deliberate — it is what makes nine different behaviours read as one
    /// creature rather than as nine marks.
    private enum Art {
        struct Frame {
            let body: [(row: Int, columns: ClosedRange<Int>)]
            let antennaRow: Int
            let eyeRow: Int
        }

        static let rest = Frame(
            body: [
                (3, 4 ... 7),
                (4, 2 ... 9),
                (5, 1 ... 10),
                (6, 1 ... 10),
                (7, 2 ... 9),
            ],
            antennaRow: 2,
            eyeRow: 5
        )

        /// One row shorter, with the dome flattened onto the shoulders. Everything else — the
        /// widest rows, the floor, the legs — is identical, so the compression reads as the
        /// creature compressing rather than as a different creature.
        static let squashed = Frame(
            body: [
                (4, 3 ... 8),
                (5, 1 ... 10),
                (6, 1 ... 10),
                (7, 2 ... 9),
            ],
            antennaRow: 3,
            eyeRow: 5
        )

        static let leftAntennaColumn = 4
        static let rightAntennaColumn = 7
        /// Two. At three they stop reading as a mood and start reading as insect feelers, which
        /// take over a sprite this small.
        static let maxAntennaLift = 2

        /// The left column of each eye.
        static let eyeColumns = [3, 7]

        /// The body's lowest row — everything above it moves together when the blob leans.
        static let bodyFloorRow = 7

        /// Two leg frames. Alternating them is the oldest walk cycle there is.
        static func legs(phase: Int) -> [(Int, Int)] {
            phase == 0
                ? [(3, 8), (4, 8), (7, 8), (8, 8), (2, 9), (9, 9)]
                : [(2, 8), (3, 8), (8, 8), (9, 8), (4, 9), (7, 9)]
        }
    }

    // MARK: Helpers

    private static func phase(_ elapsed: Double, _ period: Double) -> Double {
        let value = elapsed.truncatingRemainder(dividingBy: period) / period
        return value < 0 ? value + 1 : value
    }

    /// Two beats and a rest, peaking at 1.
    private static func heartbeat(_ elapsed: Double) -> Double {
        let phase = phase(elapsed, Theme.Motion.AgentActivity.approval)
        return max(attack(phase), attack(phase - 0.17))
    }

    /// A sharp attack with a slow decay — one beat. Zero outside `0...1`.
    private static func attack(_ t: Double) -> Double {
        guard t >= 0, t < 1 else { return 0 }
        return exp(-t * 11)
    }

    /// Clamps to `0...1` with a smoothstep in between, so nothing arrives with a corner in it.
    private static func ramp(_ t: Double) -> Double {
        let clamped = min(1, max(0, t))
        return clamped * clamped * (3 - 2 * clamped)
    }

    /// A stable pseudo-random number in `0..<1`. Seeded per view so behaviour is varied between
    /// marks but the same mark replays identically for the same elapsed time.
    private static func hash(_ n: Double) -> Double {
        let value = sin(n * 127.1 + 311.7) * 43758.5453
        return value - value.rounded(.down)
    }

    /// Timings short enough to be part of a gesture's shape rather than a rate of their own.
    private enum Timing {
        static let settle = 1.2
        static let reaction = 0.7
        static let blinkLength = 0.11
    }

    /// The parts of each motion that are *shape* rather than timing. Every duration lives in
    /// `Theme.Motion.AgentActivity`, per the app's one-file rule for curves and durations.
    private enum Figure {
        /// A finished blob does not sit at full brightness — see `done`.
        static let doneRestAlpha = 0.8
        /// Beside the head, clear of every antenna position including the startle shake.
        static let markColumn = 11
        static let z = [(0, 0), (1, 0), (1, 1), (1, 2), (2, 2)]
    }
}

/// Where the pointer is over the expanded panel, for the mascots' eyes.
///
/// An observable object rather than a plain environment value, so a moving pointer invalidates
/// only the marks reading it — not every row of the panel on every mouse move.
@Observable
@MainActor
final class MascotPointer {
    /// In the global coordinate space. `nil` when the pointer is not over the panel.
    var location: CGPoint?
}

/// Which sessions have already had a mark on screen, so only a genuinely new one beams in.
///
/// Views are rebuilt every time the panel opens, so "this view just appeared" is not "this
/// session just started". Remembering identities for the app's lifetime is. Sessions present at
/// launch are recorded without beaming — a notch full of arrivals at login is noise.
@MainActor
enum MascotArrivals {
    private static var seen: Set<String> = []
    private static let launchedAt = Date()

    static func isNew(_ identity: String) -> Bool {
        guard seen.insert(identity).inserted else { return false }
        return Date().timeIntervalSince(launchedAt) > Theme.Motion.AgentActivity.arrivalGrace
    }
}

/// Draws `AgentActivityGlyph` at a size snapped to whole pixels, on the display link.
///
/// The phase is measured from when this view last saw the status *change*, not from when it
/// appeared — see `cells(for:elapsed:context:)`.
@MainActor
struct AgentActivityGlyphView: View {
    let status: SessionStatus
    /// Nominal *height*. The sprite is wider than it is tall, so the drawn width comes out
    /// larger than this — see `drawnWidth`.
    var side: CGFloat = Theme.Metrics.Agents.mascotCollapsedSize
    /// The session this mark stands for. Lets a new session beam in once, rather than every
    /// time a view for it is built.
    var identity: String?
    /// When the session last did anything. An idle session that has been quiet long enough
    /// falls asleep even if this view has only just been built.
    var lastActivity: Date?

    /// Renders one specific instant of the motion instead of following the clock.
    ///
    /// For `FrameDump` and nothing else. `ImageRenderer` draws a `TimelineView` at whatever
    /// "now" happens to be, and every one of these is phased from its own `enteredAt` — so a
    /// dump of the running view would render all nine states at elapsed ≈ 0. Sampling explicit
    /// phases is the only way to see a motion in a still.
    var debugElapsed: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Set only when the whole tree is being rendered at a pinned instant — see
    /// `EnvironmentValues.debugMotionTime`.
    @Environment(\.debugMotionTime) private var debugMotionTime
    @Environment(MascotPointer.self) private var pointer: MascotPointer?
    @State private var enteredAt = Date()
    @State private var previous: SessionStatus?
    @State private var arrivedAt: Date?
    @State private var seed = Double.random(in: 0 ..< 1000)
    @State private var globalFrame: CGRect = .zero

    var body: some View {
        Group {
            if let elapsed = debugElapsed ?? debugMotionTime {
                sprite(elapsed: elapsed, context: baseContext)
            } else if reduceMotion {
                // Not "no animation" — a *resting* frame of each state, sampled where the pose
                // is most itself. Reduce Motion asks for less movement, not for nine states
                // that are once again the same shape in different colours.
                sprite(elapsed: Self.restingSample(for: status), context: baseContext)
            } else {
                TimelineView(.animation) { timeline in
                    sprite(
                        elapsed: timeline.date.timeIntervalSince(enteredAt),
                        context: liveContext(at: timeline.date)
                    )
                }
            }
        }
        .frame(width: drawnWidth, height: drawnHeight + headroomHeight)
        // Laid out at the grid's own height, with the headroom overflowing upward: the row
        // measures exactly what it did before the mascot could hop.
        .frame(width: drawnWidth, height: drawnHeight, alignment: .bottom)
        .clipShape(HeadroomClip(headroom: headroomHeight))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { globalFrame = $0 }
        .onChange(of: status) { old, _ in
            previous = old
            enteredAt = Date()
        }
        .onAppear {
            if let identity, MascotArrivals.isNew(identity) { arrivedAt = Date() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.label)
    }

    /// Only the expanded row's mark has room for headroom and effects. The collapsed shoulder
    /// has none above it, and at the question card's and subagents' sizes the effects are
    /// specks that read as dirt.
    private var isExpanded: Bool {
        side >= Theme.Metrics.Agents.activityGlyphSize
    }

    private var headroom: Int {
        isExpanded ? AgentActivityGlyph.headroom : 0
    }

    private var headroomHeight: CGFloat {
        pixel * CGFloat(headroom)
    }

    private var baseContext: AgentActivityGlyph.Context {
        AgentActivityGlyph.Context(headroom: headroom, effects: isExpanded)
    }

    private func liveContext(at now: Date) -> AgentActivityGlyph.Context {
        var context = baseContext
        context.seed = seed
        context.previous = previous
        context.asleep = isAsleep(at: now)
        if let arrivedAt {
            let t = now.timeIntervalSince(arrivedAt)
            if t < Theme.Motion.AgentActivity.arrival { context.arrival = t }
        }
        if isExpanded, let location = pointer?.location, globalFrame != .zero {
            context.gaze = gaze(toward: location)
        }
        return context
    }

    private func isAsleep(at now: Date) -> Bool {
        guard status == .idle else { return false }
        let after = Theme.Motion.AgentActivity.sleepAfterIdle
        if now.timeIntervalSince(enteredAt) > after { return true }
        // Idle begins `waitingForInputIdleDelay` after the last activity, so this is the same
        // threshold measured from the session rather than from this view.
        guard let lastActivity else { return false }
        return now.timeIntervalSince(lastActivity) > AgentSessionStore.waitingForInputIdleDelay + after
    }

    private func gaze(toward location: CGPoint) -> AgentActivityGlyph.Gaze {
        let reach = Theme.Metrics.Agents.mascotGazeReach
        let rise = Theme.Metrics.Agents.mascotGazeRise
        let dx = location.x - globalFrame.midX
        let dy = location.y - globalFrame.midY
        return AgentActivityGlyph.Gaze(
            dx: dx > reach ? 1 : dx < -reach ? -1 : 0,
            dy: dy < -rise ? -1 : dy > rise ? 1 : 0
        )
    }

    /// The sprite and its glow.
    ///
    /// Two passes of the same cells: a blurred copy composited additively underneath, then the
    /// crisp one on top. That is how a phosphor display behaves — the lit cell is sharp and the
    /// light around it is not. Additive rather than a plain overlay so the glow only ever
    /// brightens; a normal blend would grey the black between the cells.
    ///
    /// Both numbers are deliberately restrained. A wide, strong bloom fills the gaps between
    /// the cells and leaves a glowing blob where there was pixel art.
    private func sprite(elapsed: Double, context: AgentActivityGlyph.Context) -> some View {
        let cells = AgentActivityGlyph.cells(for: status, elapsed: elapsed, context: context)
        return ZStack {
            canvas(cells)
                .blur(radius: pixel * Self.bloomRadius)
                .blendMode(.plusLighter)
                .opacity(Self.bloomStrength)

            canvas(cells)
        }
        // The glow spills past the sprite's own bounds, so the group has to be composited
        // before the frame clips it — otherwise the bloom is sliced off square at the edges.
        .compositingGroup()
    }

    /// Blur radius as a multiple of one cell.
    private static let bloomRadius: CGFloat = 0.36
    private static let bloomStrength: Double = 0.5

    /// How far a lit edge lifts toward white and a shaded one drops toward black. The status
    /// hue is the one colour source; these only give it volume.
    private static let highlightMix: Double = 0.42
    private static let shadowMix: Double = 0.36

    /// The hairline gap between cells, in points, split either side of the cell.
    ///
    /// This is the "I can see the pixels" requirement, and it is a real gap rather than a drawn
    /// grid: each cell is inset, so the black surface shows through between them. Half a point
    /// is one device pixel on a Retina display: the smallest gap that can exist, which is all a
    /// separator has to be.
    private static let cellGap: CGFloat = 0.5

    private func canvas(_ cells: [AgentActivityGlyph.Cell]) -> some View {
        Canvas(rendersAsynchronously: false) { context, _ in
            // No gap at a 1pt cell: there is nothing to inset without erasing the cell.
            let gap = pixel >= 2 ? Self.cellGap / 2 : 0
            for cell in cells {
                let path = Path(
                    CGRect(
                        x: CGFloat(cell.column) * pixel + gap,
                        y: CGFloat(cell.row + headroom) * pixel + gap,
                        width: pixel - gap * 2,
                        height: pixel - gap * 2
                    )
                )
                // Per-cell rather than per-canvas. Alpha here is the heartbeat and the blink,
                // and compositing the whole canvas at one opacity would flatten both away.
                context.opacity = cell.alpha
                switch cell.tone {
                case .body:
                    context.fill(path, with: .style(.foreground))
                case .highlight:
                    context.fill(path, with: .style(.foreground))
                    context.opacity = cell.alpha * Self.highlightMix
                    context.fill(path, with: .color(.white))
                case .shadow:
                    context.fill(path, with: .style(.foreground))
                    context.opacity = cell.alpha * Self.shadowMix
                    context.fill(path, with: .color(.black))
                case .white:
                    context.fill(path, with: .color(.white))
                case let .accent(color):
                    context.fill(path, with: .color(color))
                }
            }
        }
    }

    /// Where each state is drawn when motion is off. Chosen to be the most legible instant of
    /// that state's cycle, not an arbitrary t=0 — `done` at zero has not hopped yet, which is
    /// the one pose that does not say "finished".
    private static func restingSample(for status: SessionStatus) -> Double {
        switch status {
        case .done: 0.5
        case .working: 0.25
        case .compacting: 1.4
        case .runningTool: 0.3
        case .needsApproval: 0.02
        case .waitingForAnswer: 0.5
        case .waitingForInput: 0.25
        case .thinking: 0.7
        default: 0
        }
    }

    /// The cell size, snapped down to a whole number of points so no row is ever half-lit.
    private var pixel: CGFloat {
        max(1, (side / CGFloat(AgentActivityGlyph.rows)).rounded(.down))
    }

    private var drawnWidth: CGFloat {
        pixel * CGFloat(AgentActivityGlyph.columns)
    }

    private var drawnHeight: CGFloat {
        pixel * CGFloat(AgentActivityGlyph.rows)
    }
}

/// The layout frame, extended upward by the headroom. Identical to `.clipped()` without it.
private struct HeadroomClip: Shape {
    let headroom: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY - headroom, width: rect.width, height: rect.height + headroom))
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 14) {
        ForEach(SessionStatus.allCases, id: \.self) { status in
            HStack(spacing: 16) {
                AgentActivityGlyphView(status: status, side: 20)
                AgentActivityGlyphView(status: status, side: 36)
                AgentActivityGlyphView(status: status, side: 72)
                Text(status.label)
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            .foregroundStyle(status.tint)
        }
    }
    .padding(24)
    .background(Color.black)
}
