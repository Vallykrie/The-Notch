import AppKit
import SwiftUI

/// Shared visual and motion tokens for the notch.
///
/// Surfaces must never hardcode an animation curve, duration, corner radius, padding, font, or
/// colour; add or tune those values here so every transition remains one coherent gesture and
/// the whole app keeps one voice.
@MainActor
enum Theme {
    enum Motion {
        /// The one spring that drives the whole expansion gesture — the aperture's width,
        /// height, and corner radii, nothing else. Content does not animate; it is uncovered
        /// by this.
        ///
        /// Open and close are deliberately *different* springs. Opening is slightly
        /// under-damped so the panel reads as the notch physically stretching; closing is
        /// critically damped, because an overshoot on the way out looks like a bug rather
        /// than a flourish. Matching the reference on this one detail is most of why it
        /// feels expensive.
        ///
        /// Both were re-tuned after measuring the rendered frames rather than trusting the
        /// numbers. The old open (0.42 / 0.8) overshot by 1.2% — three device pixels, well
        /// under the threshold anyone perceives — so it paid an under-damped spring's full
        /// settling cost and still just *arrived*. The old close (0.45 / 1.0) was worse: the
        /// last 30pt of a 278pt travel took 200ms, a sub-perceptual crawl long after the
        /// pointer had gone. A close must clear out at least as decisively as the open opens.
        static let open = Animation.spring(
            response: 0.38,
            dampingFraction: 0.72,
            blendDuration: 0
        )
        /// The close is deliberately NOT a spring, and three failed retunes are the reason.
        ///
        /// 0.45/1.0 took 350ms with a 200ms sub-perceptual tail. 0.34/0.92 took 283ms with a
        /// 150ms tail. 0.26/1.0 covered 81% of the travel in 66ms and then spent 167ms — 56%
        /// of the gesture — on the last 10.5pt, ending up *longer* than the version it
        /// replaced and 39% slower than the 216ms open it was supposed to beat.
        ///
        /// That is not a tuning failure, it is arithmetic. A critically damped spring settles
        /// as (1 + wt)e^-wt, which is asymptotic by construction; `response` scales the tail
        /// but cannot remove it. Measured against w = 2pi/0.26, 1% remaining lands at 274ms —
        /// exactly the frame where it was observed. No value of `response` fixes this.
        ///
        /// A finite timing curve terminates. It keeps the no-overshoot requirement a close
        /// needs — an overshoot on the way out reads as a bug, not a flourish — and it ends,
        /// decisively, before the open would have.
        ///
        /// The first timing curve fixed the tail and relocated the defect to the head: 0.24/0.9
        /// front-loaded 90% of the travel into the first 24% of the duration, so the close
        /// delivered 68% of its distance in a single 16.6ms frame and ran in three visible
        /// frames against the open's eleven. One gesture became two different physical
        /// objects — a panel that stretches open and then vanishes. Peak per-frame velocity
        /// must stay near the open's, which measured 40.5pt at its fastest frame.
        ///
        /// 0.33/0.0/0.15/1.0 at 0.18s was the version that fixed the *tail* and still lost the
        /// gesture, because chasing "at least as decisive as the open" had been the wrong target
        /// all along. Those two directions are not symmetric problems. Opening is a response to
        /// the pointer arriving and has to feel immediate; closing happens 220ms after the
        /// pointer has already left, when the user is looking somewhere else entirely, and a
        /// 640x190 panel that disappears in eleven frames at the edge of vision reads as a
        /// glitch — something blinked out, rather than something withdrew.
        ///
        /// So the close is now *longer* than the open (0.32s against 0.216s of visible travel)
        /// and its peak per-frame velocity is deliberately below the open's rather than near
        /// it. The head is softened too — 0.42 against the old 0.33 — because the first thing
        /// that happens on a close is the panel leaving from under a pointer that has just
        /// walked off its edge, and a hard start there is what made it snap. It still
        /// terminates, which is the whole reason this is a timing curve and not a spring, and
        /// it still never overshoots.
        static let close = Animation.timingCurve(0.42, 0.0, 0.22, 1.0, duration: 0.32)

        /// Anything the pointer is directly dragging. Lower response than `open` so it tracks
        /// the finger instead of trailing it.
        static let interactive = Animation.interactiveSpring(
            response: 0.38,
            dampingFraction: 0.8,
            blendDuration: 0
        )

        /// A panel that is already open changing size because its content changed.
        static let resize = Animation.spring(
            response: 0.45,
            dampingFraction: 1.0,
            blendDuration: 0
        )
        static let content = Animation.smooth(duration: 0.22)

        /// The media panel turning into its lyrics view and back. One spring for the whole
        /// change: the scrubber and transport buttons travel from their rows under the title to
        /// the strip along the bottom (shrinking as they go), the title rows fade out and the
        /// lyrics fade in. Critically damped — the controls are landing in a tight strip, and an
        /// overshoot would bounce them past it.
        static let lyricsMode = Animation.spring(
            response: 0.42,
            dampingFraction: 1.0,
            blendDuration: 0
        )

        /// The lyrics reel moving to the next line. One spring drives the whole step — the
        /// column's glide, the sung line growing to full size and its neighbours receding —
        /// so the line change reads as one object moving, not three things cross-fading.
        /// Slightly under-damped: the new line settles into place with a little give, which is
        /// what makes the step feel physical. Long enough to read as a glide, short enough to
        /// be finished well before the next line, which in fast songs comes ~1s later.
        static let lyricsAdvance = Animation.spring(
            response: 0.5,
            dampingFraction: 0.78,
            blendDuration: 0
        )

        /// Cross-fading the collapsed and expanded children of the shell. Deliberately much
        /// shorter than the aperture spring: the point is that content is *uncovered*, not
        /// that it dissolves. Without this the collapse deleted the panel's contents on frame
        /// one and the user watched an empty black box deflate for a third of a second.
        ///
        /// Split into an exit and an entry because a *symmetric* cross-fade between two
        /// different layouts is a smear rather than a dissolve: for two frames the notch had
        /// two legible titles sixteen pixels apart. The outgoing child must be gone before the
        /// incoming one is readable, so the entry is delayed past the end of the exit.
        ///
        /// Both were scaled up with the close when it went 0.18 → 0.32. They are not free to
        /// drift from it: the exit at 0.07 resolved inside the first fifth of the new close, so
        /// the expanded panel's contents were gone while three quarters of the silhouette's
        /// travel was still to come — an empty black box deflating, which is the exact defect
        /// the split was introduced to fix. The pair keeps its old relationship (the entry
        /// starts just as the exit lands) at the new duration.
        static let contentExit = Animation.easeOut(duration: 0.11)
        static let contentEnter = Animation.easeIn(duration: 0.14).delay(0.10)

        /// The scale and blur that soften content as the aperture edge sweeps across it. This
        /// is deliberately NOT `contentExit`/`contentEnter`: opacity should resolve fast, but
        /// the blur has to outlast the aperture's travel or it switches off during exactly the
        /// window where the edge is still bisecting glyphs — which is what happened when all
        /// three shared one 0.12s curve and the blur was at zero by 66ms with the edge still
        /// crossing content at 166ms.
        /// `easeIn`, not `easeOut`. The blur has to *outlast* the aperture's travel, and an
        /// ease-out is 55% resolved at 66ms — by which point the aperture still had 13.5pt of
        /// horizontal and 22.5pt of vertical travel left, and was caught bisecting the "%"
        /// glyph with a hard three-pixel step. Easing in puts roughly 11% resolution at the
        /// same moment and still clears before the open settles.
        /// 0.20 was tuned against a 0.18s close and a 0.38 open. It survives the open unchanged
        /// but no longer clears the close, so it moves with it.
        static let contentEntry = Animation.easeIn(duration: 0.26)

        /// The interior lift and the drop shadow leaving on the way down. They must be gone
        /// before the silhouette finishes shrinking — a shadow cast by a shape already flush
        /// against the bezel, and a lift gradient on a resting notch, both advertise that the
        /// notch is a drawn window rather than the hardware cutout.
        /// Must stay strictly shorter than the close's time-to-final-pixel. At 0.12 against a
        /// close whose visible travel is ~100ms, the ordering inverted: the shadow was still
        /// painting a penumbra ring around a silhouette that had already reached its resting
        /// size — a halo around a notch at rest, which is the exact artefact this exists to
        /// prevent. Re-check this against the close whenever the close changes.
        ///
        /// Re-checked, and raised, when the close went to 0.32. 0.09 was not merely safe there,
        /// it was the other half of why the close looked cheap: the drop shadow — the largest
        /// soft-edged thing on screen, and the only part of the panel painting outside the
        /// silhouette — cut out in 90ms while the panel it belonged to still had 230ms of
        /// travel left. The panel appeared to lose its depth first and then move, as two events.
        /// 0.18 keeps the ordering (it lands well inside the close's ~300ms of visible travel)
        /// while the shadow now leaves *with* the panel rather than ahead of it.
        static let surfaceFade = Animation.easeOut(duration: 0.18)
        static let accent = Animation.spring(.bouncy(duration: 0.4))

        /// One cycle of each agent state's mark. See `AgentActivityGlyph`, which owns the
        /// shapes; these own how fast they happen.
        ///
        /// They live here rather than beside the functions that read them because the ground
        /// rule is that every duration in the app is in this file, and "these are internal to
        /// one animation" is exactly the argument that ends with curves scattered across
        /// surfaces. The numbers are not arbitrary: `cursor` is a real terminal's blink rate,
        /// which is most of why that mark is recognised rather than decoded, and `idle` is the
        /// slowest thing in the app on purpose.
        enum AgentActivity {
            static let working = 1.1
            static let thinking = 1.35
            static let tool = 1.15
            static let compacting = 1.7
            static let approval = 1.5
            static let question = 2.0
            static let cursor = 1.06
            static let idle = 3.6
            /// The one-shot hop a finished session makes when it lands.
            static let doneDraw = 0.5

            /// One wag of a finished session's antennae, side to side.
            ///
            /// Deliberately unlike `thinking` (1.35), which is the other state whose antennae
            /// move in opposition — a slow sway there, a quicker wiggle here. Two states sharing
            /// a channel have to differ in *rate* or they read as the same behaviour in two
            /// colours, and this is the pair most at risk of it.
            ///
            /// Also deliberately slower than any of the busy states. A finished row that moves
            /// as fast as a working one is claiming to still be doing something.
            static let doneWag = 0.8

            // What makes the mascot alive rather than animated — see `AgentActivityGlyph`.

            /// One natural blink lands somewhere in each window, placed per mark from its seed,
            /// so a panel of blobs never blinks in unison.
            static let blinkWindow = 3.3
            /// One fidget (a glance, a double-blink, an antenna twitch, a hop) per window in
            /// the calm states, and how long each lasts.
            static let fidgetWindow = 4.2
            static let fidgetLength = 1.1

            /// The startle when approval arrives: a jump, then a shiver until `startleShake`,
            /// with a flashing "!" beside the head until `startleMark`.
            static let startleJump = 0.18
            static let startleShake = 0.6
            static let startleMark = 1.4
            /// Legs revving before a walk settles; also the squeeze into compacting and the
            /// turn to face you when a turn ends.
            static let revUp = 0.45
            /// When a finished blob's second, victory hop lands, and when its confetti fires.
            static let secondHop = 0.95
            static let confettiDelay = 1.1
            static let confettiLife = 1.3
            /// A finished blob sparkles once per `twinkle`, starting after the celebration.
            static let twinkle = 2.2
            static let twinkleAfter = 2.4

            /// How long an idle session stays awake. Idle already means five quiet minutes, so
            /// this is ten minutes since the agent last did anything.
            static let sleepAfterIdle: TimeInterval = 5 * 60
            /// One breath of a sleeping blob, and one rise of its Z's. Slower than anything
            /// awake, on purpose.
            static let breath = 2.85
            static let snore = 3.2

            /// A new session beaming in.
            static let arrival = 0.7
            /// Sessions already running when the app launches do not beam in.
            static let arrivalGrace: TimeInterval = 5
        }

        /// The collapsed pill's attention ring travels its rim once per this interval.
        ///
        /// Was 3.2, against a sweep that covered the whole closed silhouette. The ring now
        /// traces only the *visible* rim, which is a little over half that length — so 3.2
        /// would have halved a speed that was already reading as a slow drift. 2.2 puts the
        /// head at roughly 270pt/s across the resting silhouette: fast enough to catch
        /// peripheral vision, which is the entire job, and well short of the strobing that
        /// makes a notification feel like an alarm.
        static let ringPeriod: TimeInterval = 2.2

        /// The resting silhouette growing or losing its shoulders because a live activity
        /// started or ended. Slower and softer than `open`: this happens unprompted, without
        /// the user's pointer anywhere near the notch, so it must not snap into the corner of
        /// their eye. Critically damped for the same reason.
        static let shoulders = Animation.spring(
            response: 0.55,
            dampingFraction: 1.0,
            blendDuration: 0
        )

        /// One full cycle of the collapsed now-playing waveform.
        static let waveformPeriod: TimeInterval = 1.15

        /// One step of the record in the empty media panel. The glint jumps an eighth of a
        /// turn per step rather than rotating smoothly, because a pixel grid that rotates by
        /// fractions of a cell is a smear; eight steps of 0.225s is one turn in 1.8s, which is
        /// 33⅓ rpm.
        static let vinylStep: TimeInterval = 0.225

        /// Measured end to end, 60ms of debounce plus ~50ms to the first perceptible frame
        /// put 110ms between the pointer arriving and the notch acknowledging it, which is
        /// past the point where a surface stops feeling directly manipulated. Not zero,
        /// though: the collapsed region sits in the middle of the menu bar and the pointer
        /// crosses it on the way between menu bar items, so some debounce still earns its
        /// keep. The exit delay is untouched — the grace zone on the way out does different
        /// work and 220ms is right for it.
        static let hoverEnterDelay: Duration = .milliseconds(40)
        static let hoverExitDelay: Duration = .milliseconds(220)

        /// The same two delays, per `HoverSensitivity`. `.standard` is the pair above and must
        /// stay identical to it — that pairing is what makes "Restore Defaults" put the hover
        /// back to the behaviour the two comments above were tuned for.
        ///
        /// `.instant` still keeps a non-zero exit delay. Zero on the way *in* is a legitimate
        /// preference on a quiet menu bar; zero on the way *out* is not a preference, it is a
        /// panel that collapses whenever the pointer crosses a rounded corner on its way to a
        /// button inside it.
        static func hoverEnterDelay(_ sensitivity: HoverSensitivity) -> Duration {
            switch sensitivity {
            case .instant: .zero
            case .standard: hoverEnterDelay
            case .relaxed: .milliseconds(220)
            }
        }

        static func hoverExitDelay(_ sensitivity: HoverSensitivity) -> Duration {
            switch sensitivity {
            case .instant: .milliseconds(120)
            case .standard: hoverExitDelay
            case .relaxed: .milliseconds(450)
            }
        }

        static func forState(_ state: NotchState) -> Animation {
            state == .expanded ? open : close
        }
    }

    enum Metrics {
        enum Trading {
            static let shoulderWidth: CGFloat = 72
            static let fauxHousingGap: CGFloat = 8
            static let detailWidth: CGFloat = 250
            /// Extra inset inside the shared panel padding. The other surfaces open on a filled
            /// block — artwork, a mascot — that carries the edge; this one opens on bare text,
            /// which at the same inset looked jammed against the panel's side.
            static let contentInset: CGFloat = 12
        }
        static let fauxNotchSize = CGSize(width: 188, height: 32)
        /// 190 tall was a guess, and measured against real content it was 35% empty: the
        /// battery column had a 67pt void with the word "Good" stranded at the floor of it.
        /// Distributing that surplus inside the columns only turned one horizontal dead band
        /// into two vertical ones. The panel is now sized to the content it actually has;
        /// earning more height means giving the columns more to say first.
        /// Re-measured when the panel stopped holding battery and calendar columns and
        /// started holding a media player. 160 tall could not fit the tab bar, 96pt of
        /// artwork, and a transport row without one of them being squeezed; the panel is
        /// sized to the tallest surface it actually shows, which is media.
        ///
        /// 26 (tab bar) + 10 (header spacing) + 96 (artwork / metadata column) plus the
        /// vertical padding and the two content insets comes to 178; 190 leaves the
        /// transport row a margin it can breathe in rather than sitting on the bottom curve.
        static let expandedNotchSize = CGSize(width: 640, height: 190)

        static let collapsedTopCornerRadius: CGFloat = 6
        static let collapsedBottomCornerRadius: CGFloat = 14
        static let expandedTopCornerRadius: CGFloat = 19
        static let expandedBottomCornerRadius: CGFloat = 24

        static let collapsedHorizontalPadding: CGFloat = 13
        static let collapsedVerticalPadding: CGFloat = 6
        /// Must clear `expandedTopCornerRadius`: the top corners curve *inward*, so content at
        /// the top of the panel is clipped by them unless it is inset past the curve.
        static let expandedHorizontalPadding: CGFloat = 28
        static let expandedVerticalPadding: CGFloat = 18
        static let collapsedContentSpacing: CGFloat = 6
        static let expandedContentSpacing: CGFloat = 14

        // `statusDotCollapsedSize` (6) and `statusDotExpandedSize` (8) lived here and are gone
        // with the dot they sized. Neither was a multiple of 8, which was fine for a circle and
        // is not fine for the pixel-grid mark that replaced it — see
        // `Theme.Metrics.Agents.activityGlyphSize`.

        /// Sprites render at whole multiples of 8; these are already multiples.
        static let glyphCollapsedSize: CGFloat = 8
        static let glyphExpandedSize: CGFloat = 16
        static let expandedTrackingInset: CGFloat = 28
        static let bezelOverlap: CGFloat = 2

        /// Slack around the expanded silhouette inside the panel. The panel must be larger
        /// than the notch itself or the drop shadow is clipped away.
        static let panelHorizontalMargin: CGFloat = 90
        static let panelBottomMargin: CGFloat = 70

        /// Breathing room between the housing and the first piece of content on a shoulder.
        static let shoulderInset: CGFloat = 6

        static let expandedTopContentInset: CGFloat = 6
        /// The panel's rounded bottom corners cut into the last row of content the same way the
        /// top corners cut into the header, so the floor needs its own clearance.
        static let expandedBottomContentInset: CGFloat = 4
        /// The shell owns the full gap between the header and every expanded surface.
        /// Surfaces add bottom clearance only, so top padding cannot stack with this gap.
        static let expandedHeaderSpacing: CGFloat = 10
        /// "THE NOTCH" is all caps and never uses its descender space, so a symmetric
        /// `expandedHeaderSpacing` renders 12.5pt above the header rule and 9.5pt below it.
        /// The token is symmetric; the ink is not.
        static let headerBaselineCompensation: CGFloat = 3

        /// Between the two columns of the expanded shell, either side of the vertical rule.
        static let expandedColumnSpacing: CGFloat = 22

        /// Content entering with the aperture. The aperture alone is a curtain wipe: text sits
        /// stationary in screen space while a hard edge sweeps across it, bisecting glyphs at
        /// full opacity. The blur is the part that matters — a half-rendered letter behind a
        /// few points of blur reads as a soft edge instead of a cut.
        static let contentEntryScale: CGFloat = 0.94
        /// 3pt behind a 120ms ramp measured as doing nothing. The blur only has to survive
        /// the aperture's travel to earn its place; see `Theme.Motion.contentEntry`.
        static let contentEntryBlur: CGFloat = 4

        // The interior lift gradient and the rim hairline used to live here, and both are gone
        // on purpose. They were the only two things painting gradation into the notch, and
        // gradation is exactly what reveals the seam between the drawn surface and the
        // physical cutout — the surface has to be pitch black to blend with the real notch.
        // Do not reintroduce either as a "subtle" value; at any strength above zero the edge
        // of the drawn shape becomes findable, which is the defect.

        /// The collapsed live-activity strip: what plays on the shoulders when something is
        /// actually happening. Everything here has to read at 8–20pt beside a camera housing.
        enum LiveActivity {
            static let artworkSize: CGFloat = 18
            static let artworkCornerRadius: CGFloat = 4
            /// The shoulder a live activity gets: exactly one glyph-sized mark, and nothing
            /// else.
            ///
            /// This went 128 → 92 → 40, and each step removed *text* rather than shrinking it.
            /// At 128 the shoulder held artwork, title and artist; at 92 it held a truncated
            /// title; neither was legible enough to be worth the silhouette it cost. A title
            /// clipped mid-word is not information, it is a wider black bar lying across the
            /// menu bar — and the whole appeal of this app is that the drawn surface is
            /// indistinguishable from the hardware cutout.
            ///
            /// So the collapsed notch now answers *what is live* with pictures only: artwork,
            /// a waveform, a status sprite, a count. 40 is `compactHorizontalPadding` +
            /// `artworkSize` + `shoulderInset` with a couple of points of slack, which means the
            /// content reaches both edges of its shoulder and there is no dead black band at
            /// either end. The untruncated title lives in the expanded panel, which is what the
            /// expanded panel is for.
            ///
            /// Symmetric, and it has to stay symmetric — see `NotchCoordinator.collapsedSize`.
            static let compactShoulderWidth: CGFloat = 40

            /// The HUD is the one collapsed case that is *deliberately* wider than the rest.
            ///
            /// A volume or brightness readout is a continuous quantity, and a level bar only
            /// works if it is long enough to resolve a step of 1/16 — `HUD.barWidth` is 62pt
            /// for that reason, and the leading shoulder carries a device name beside it. It
            /// also lasts a second and a half rather than for as long as a song, so the wider
            /// silhouette is a momentary answer to a key press rather than something parked
            /// over the menu bar. The contrast between the two widths is the point: a notch
            /// that grows when you press a key reads as a response.
            static let hudShoulderWidth: CGFloat = 92

            /// The intro's closing shoulder: the mascot on one side, "ready" on the other. Wide
            /// enough for the word at caption size and nothing more.
            static let welcomeShoulderWidth: CGFloat = 64
            static let welcomeDotSize: CGFloat = 4

            /// Outer padding on a compact shoulder. Tighter than
            /// `Metrics.collapsedHorizontalPadding`, which is sized for text: a 40pt shoulder
            /// spends 16pt of its width on padding and inset already, and at 13 the artwork
            /// would not fit its own shoulder.
            static let compactHorizontalPadding: CGFloat = 10
            static let mediaVerticalPadding: CGFloat = 4
            /// Five bars at 2pt on 2pt gaps is 18pt across — exactly `artworkSize`, so the
            /// waveform on the trailing shoulder and the artwork on the leading one are the
            /// same square and the collapsed strip reads as a matched pair rather than as two
            /// unrelated marks. The bar count was 4 while this was only ever the *fallback*
            /// drawn inside the artwork frame; it is now a shoulder of its own.
            static let waveformBarCount = 5
            static let waveformBarWidth: CGFloat = 2
            static let waveformBarSpacing: CGFloat = 2
            static let waveformCornerRadius: CGFloat = 1
            static let waveformMinHeight: CGFloat = 3
            static let waveformMaxHeight: CGFloat = 14
            /// How often the now-playing state is polled while a player is running. Nothing is
            /// polled at all when no supported player process exists.
            static let pollInterval: TimeInterval = 2
        }

        enum Control {
            static let cornerRadius: CGFloat = 6
            static let horizontalPadding: CGFloat = 10
            static let verticalPadding: CGFloat = 5
            /// For a control that is one of a stack rather than one of a row — see
            /// `ButtonStyle.notchCompact`. Two points a side, which is where a capsule around
            /// 11pt type stops reading as a button; below it the row is just text on a tint.
            static let compactVerticalPadding: CGFloat = 3
            static let fillOpacity: CGFloat = 0.12
            static let pressedFillOpacity: CGFloat = 0.2
            static let borderOpacity: CGFloat = 0.14
            static let borderWidth: CGFloat = 0.75
        }

        /// The shadow survives the pitch-black rule above because it is black, and it is cast
        /// *outside* the silhouette. It is what stops the expanded panel floating unanchored
        /// on a light desktop; it paints nothing inside the shape.
        static let shadowRadius: CGFloat = 22
        static let shadowOpacity: CGFloat = 0.55
        static let shadowYOffset: CGFloat = 10
        /// Exactly one device pixel, for separators *inside* the panel. A 0.75pt line rounded
        /// *up* to 2px for the horizontal rule and *down* to 1px for the vertical one — the
        /// same token rendering at two different weights, 22pt apart in the same panel, which
        /// reads as a hierarchy nobody designed. Separators snap to the device grid instead of
        /// being asked to.
        static var hairline: CGFloat { 1 / (NSScreen.main?.backingScaleFactor ?? 2) }

        /// The attention ring: a light travelling the silhouette's rim while an agent is
        /// blocked on the user. See `AttentionRingView` for why it traces a trimmed path
        /// rather than sweeping an angular gradient.
        enum Ring {
            /// 1.5 rendered as a grey thread beside 13pt type on a pure-black surface — thin
            /// enough that the glow underneath was doing all of the work and the head had no
            /// edge of its own. 2 is one clean device pixel at 2x either side of the path
            /// centre, which is the narrowest a *lit* line can be and still read as lit.
            static let lineWidth: CGFloat = 2

            /// The rim that is on the whole time the ring is lit, under the travelling head.
            /// Low enough not to read as a border around the notch — which would defeat the
            /// entire point of a surface that pretends to be the hardware cutout — and high
            /// enough that the light has something to travel along.
            static let restingOpacity: CGFloat = 0.16
            /// Reduce Motion has no travelling head, so the rim is the whole signal and has to
            /// carry it alone.
            static let staticOpacity: CGFloat = 0.62

            /// How much of the visible rim the comet spans, head to end of tail.
            ///
            /// A third. Shorter than that and the rim is mostly dark, so the eye has to find a
            /// small bright dot in the corner of its vision — the opposite of what a peripheral
            /// signal should ask for. Much longer and the head stops being a head: at 0.6 the
            /// tail wraps far enough that both ends of the rim are lit at once and it reads as
            /// a pulsing outline rather than as something moving.
            static let cometLength: CGFloat = 0.34
            /// Steps the tail is drawn in. This is the *bit depth* of the taper, not a detail
            /// of it: with a squared falloff the steps near the head are the widest, and at 14
            /// they are about 13% of full brightness apart, which the rendered filmstrip showed
            /// as a tail that reads as a dashed line. 48 puts the step under 4%, below where the
            /// eye resolves a band on a 2pt line. These are `GraphicsContext` strokes of one
            /// prebuilt path inside a single `Canvas`, which is what makes 48 of them per frame
            /// (96 with the glow) cheaper than the 14 `Shape` views this replaced.
            static let tailSegments = 48
            /// How much narrower the end of the tail is than the head, as a fraction.
            ///
            /// Zero, which is not where this started. The tail was drawn with a width taper as
            /// well as a brightness ramp, on the reasoning that a line which also thins reads as
            /// one that is moving. It does — and it also cannot tile. Two butt caps meeting at
            /// the same point have complementary partial coverage that sums to exactly one *only
            /// if the two strokes are the same width*; at different widths the joint is a step,
            /// and the step antialiases into a dark pixel. Sampling the rendered tail found one
            /// at every step boundary, about 10% down, all the way along it.
            ///
            /// Removing the taper took the worst dip from 26/255 to 3/255 and made the ramp
            /// monotone. The comet loses nothing for it: the head is still round-capped, the
            /// glow underneath is still wider than the crisp copy, and the brightness ramp was
            /// always doing most of the work. Do not reintroduce a per-step width without
            /// re-measuring — the seam is invisible in a diff and obvious in a pixel sample.
            static let tailNarrowing: CGFloat = 0
            /// How far each tail segment is extended backwards, as a fraction of its own length,
            /// so consecutive segments overlap instead of abutting.
            ///
            /// Zero, and measured rather than assumed.
            ///
            /// The tail was overlapped at 0.5 on the theory that `.lighten` would resolve the
            /// shared region to the brighter of the two steps instead of their sum. That is only
            /// half true, and the half it gets wrong is the half that matters: a blend mode
            /// operates on *colour* channels, while alpha composites with source-over
            /// regardless. So an overlapped region still accumulated coverage, and sampling the
            /// rendered tail's red channel found exactly the ripple that predicts — alternating
            /// runs of one-fold and two-fold coverage, about 13% apart, repeating at the step
            /// pitch.
            ///
            /// Abutted butt caps are the correct answer and need no trick: two antialiased edges
            /// meeting at the same coordinate have complementary partial coverage that sums to
            /// exactly one, so there is neither a seam nor a doubled band. `trimmedPath` shares
            /// an endpoint exactly between consecutive steps, which is what makes that hold.
            static let segmentOverlap: CGFloat = 0

            /// The soft copy drawn under the crisp one. This is the part that reads as light
            /// rather than as ink.
            static let glowBlur: CGFloat = 3.5
            static let glowWidthScale: CGFloat = 1.6
            static let glowOpacity: CGFloat = 0.55

            /// How much of each end of the rim the light fades across.
            ///
            /// The rim is an open path that starts and ends at the top corners, where the
            /// silhouette meets the display bezel. Fading there means the head does not stop
            /// and restart in open screen — it passes behind the bezel and comes back out the
            /// other side, which is the only reading of the loop that has no seam in it.
            static let edgeFade: CGFloat = 0.12

            /// How far outside the silhouette's edge the light's centreline runs.
            ///
            /// The ring used to be inset by half its own width, so it travelled *inside* the
            /// aperture — over the surface the panel draws on, where it competes with content
            /// and reads as a border drawn on the black rather than as something orbiting the
            /// hardware. It now rides just outside the edge, on the desktop, where nothing else
            /// is ever drawn: the notch stays a clean black cutout and the light is
            /// unmistakably around it.
            ///
            /// 2 is one full line width clear of the edge — enough that the stroke's inner
            /// edge does not touch the silhouette at 2x, close enough that it still reads as
            /// belonging to the notch rather than as a stray line under the menu bar.
            static let outset: CGFloat = 2

            /// Room the ring's canvas keeps outside the stroke so the blurred copy is not
            /// clipped by its own bounds. A `Canvas` clips to its frame, and the glow is drawn
            /// at `glowWidthScale` through a `glowBlur` filter — without this the light was
            /// cut off square along the panel's edge.
            static let bleed: CGFloat = glowBlur * 2 + lineWidth
        }



        /// The collapsed now-playing progress bar: the track's elapsed fraction, occupying
        /// the status shoulder that otherwise holds one small glyph in a field of black.
        ///
        /// 2pt at 0.18 measured as a flat luminance-46 hairline on pure black — at the edge of
        /// visibility, and indistinguishable from decoration when the elapsed fraction is zero.
        /// A progress bar has to read as a progress bar before it has any progress to show.
        enum MediaProgress {
            static let trackWidth: CGFloat = 64
            static let trackHeight: CGFloat = 3
            static let cornerRadius: CGFloat = 1.5
            static let trackOpacity: CGFloat = 0.24
        }

        /// The expanded media panel: the reference layout is artwork on the left, then title,
        /// artist, a scrubber with elapsed and total, and a transport row beneath.
        enum MediaPanel {
            // Fill the media body below the compact header without leaving a deep empty floor.
            static let artworkSize: CGFloat = 128
            static let artworkCornerRadius: CGFloat = 6
            static let columnSpacing: CGFloat = 18
            static let scrubberHeight: CGFloat = 4
            /// The scrubber's *hit* height, which is not its drawn height. A 4pt-tall drag
            /// target sits at the very top of the screen where the cursor is already fighting
            /// the menu bar; the bar draws at `scrubberHeight` and accepts the drag across
            /// this much vertical space around it.
            static let scrubberHitHeight: CGFloat = 20
            static let scrubberCornerRadius: CGFloat = 2
            static let scrubberTrackOpacity: CGFloat = 0.22
            static let transportSpacing: CGFloat = 22
            static let transportGlyphSize: CGFloat = 16
            static let primaryTransportGlyphSize: CGFloat = 24
            static let sourceBadgeSize: CGFloat = 18
            /// Spread metadata and transport across the larger artwork's height.
            static let rowSpacing: CGFloat = 12
            /// Holds "12:34" in Departure Mono at caption size:
            /// `Typography.width(characters: 5, at: 9)`. Fixed so the scrubber does not
            /// shift sideways every time the elapsed digit count changes.
            static let timeColumnWidth: CGFloat = 28
            /// The scrubber row's gap between a time label and the track itself.
            static let scrubberSpacing: CGFloat = 8
            /// Transport buttons get a hit target far larger than their glyph. A 16pt sprite
            /// is a 16pt click target otherwise, which is unusable against a moving cursor
            /// near the top edge of the screen.
            static let transportHitSize: CGFloat = 30
            static let primaryTransportHitSize: CGFloat = 38
            /// The circular field behind the play/pause control, which is the only transport
            /// affordance that needs to be findable without reading the row.
            static let primaryFillOpacity: CGFloat = 0.1
            static let pressedScale: CGFloat = 0.88
            /// A disabled transport control (no player, or a player that cannot seek) stays
            /// on screen at this opacity rather than disappearing — a transport row whose
            /// buttons come and go is harder to use than one with a dimmed button.
            static let disabledOpacity: CGFloat = 0.28

            /// The pixel record that sits in the artwork slot when nothing is playing. A
            /// 21-cell grid at 88pt floors to a 4pt cell — chunky enough to read as the same
            /// pixel art as the glyphs, with an odd count so the spindle hole has a centre cell.
            /// Lyrics mode: the right column's rows, the gap between them, and the folded
            /// transport strip — collapsed-size glyphs in a hit box just tall enough to aim at.
            static let stageSpacing: CGFloat = 6
            static let miniSpacing: CGFloat = 6
            static let miniGlyphSize: CGFloat = 10
            static let miniHitSize: CGFloat = 22
            /// The reel. Every line is set in `title`; the lines either side of the sung one
            /// shrink, and fade by distance: one away is readable, two is a hint, three is gone.
            static let lyricsLineSpacing: CGFloat = 5
            static let lyricsNeighbourScale: CGFloat = 0.8
            static let lyricsFadeByDistance: [Double] = [1, 0.4, 0.14, 0]
            /// The fade at the reel's top and bottom edges, so lines arrive and leave rather
            /// than being cut by the frame.
            static let lyricsEdgeFade: CGFloat = 12
            /// How often the reel re-reads the playback position, to notice the next line
            /// starting. The player only reports it every 2s; the position in between is
            /// extrapolated by `LyricsController`.
            static let lyricsTick: TimeInterval = 0.1
            /// Pauses before the quiet retries of a failed lyrics lookup. Two retries over
            /// eight seconds rides out a dropped request or a slow moment at the service
            /// without leaving the panel on "Looking up…" for long when it really is down.
            static let lyricsRetryDelays: [Double] = [2, 6]
            static let vinylSize: CGFloat = 88
            static let vinylGrid = 21
        }

        /// The segmented switch at the top of the expanded panel. It is the only chrome in the
        /// app the user operates directly, so it gets a real hit target rather than a hairline.
        ///
        /// It used to be centred, which put it directly underneath the camera housing — the
        /// one strip of the panel the user physically cannot see. It now sits at the top left,
        /// and it is smaller: chrome the user needs once per session should not be the largest
        /// thing in the header.
        enum TabBar {
            static let height: CGFloat = 20
            static let cornerRadius: CGFloat = 5
            static let horizontalPadding: CGFloat = 8
            static let spacing: CGFloat = 3
            static let selectedFillOpacity: CGFloat = 0.14
            static let trackFillOpacity: CGFloat = 0.06
        }

        /// The brightness and volume readout that replaces macOS's own HUD.
        ///
        /// It borrows the collapsed shoulders rather than inventing a surface: icon and label
        /// on the left, level bar on the right, the camera housing as the gap. That is the
        /// same arrangement the live activities use, so a HUD arriving over a playing track is
        /// one silhouette morphing rather than two different objects swapping places.
        enum HUD {
            /// How long the readout stays after the last change. Long enough to read a level
            /// the user is still adjusting, short enough that a single key tap does not park a
            /// black bar over the menu bar.
            static let dwell: TimeInterval = 1.5

            /// The same dwell, per `HUDDwell`. `.standard` is the value above and must stay
            /// identical to it, for the same reason the hover delays do.
            static func dwell(_ choice: HUDDwell) -> TimeInterval {
                switch choice {
                case .brief: 0.8
                case .standard: dwell
                case .long: 3.0
                }
            }
            /// Brightness has no change notification we can rely on without private
            /// notification registration, so it is polled. 20 Hz is under the threshold where
            /// a key tap feels laggy and is a trivial IOKit read each time.
            static let brightnessPollInterval: TimeInterval = 0.05
            /// How long an ungranted launch waits between attempts to install the media-key
            /// tap. Accessibility is granted in System Settings, minutes after launch and with
            /// no notification to observe, so the only options are to poll or to require a
            /// restart. Five seconds is imperceptible against a trip to System Settings and
            /// costs one failed `tapCreate` each time.
            static let permissionPollInterval: TimeInterval = 5
            /// One press of a volume or brightness key. This is macOS's own step — sixteen
            /// presses cross the whole range — and matching it is what makes the notch a
            /// replacement for the system HUD rather than an imitation with different physics.
            static let keyStep: Float = 1.0 / 16
            /// Shift+Option is macOS's quarter-step modifier on the same keys.
            static let fineKeyStep: Float = 1.0 / 64
            static let barWidth: CGFloat = 62
            static let barHeight: CGFloat = 4
            static let barCornerRadius: CGFloat = 2
            static let barTrackOpacity: CGFloat = 0.2
            static let glyphSize: CGFloat = 8
            static let contentSpacing: CGFloat = 7
            /// The level bar fills toward the trailing edge, so it is pinned to the shoulder's
            /// outer edge and never drifts with the label opposite it.
            static let barMinimumFraction: CGFloat = 0.02
        }

        /// The settings panel, which has to fit every preference the app has inside the same
        /// 640x190 silhouette every other surface uses — there is no second window to overflow
        /// into, and growing the panel for one surface would grow it for all of them.
        ///
        /// That constraint is why the layout is three columns of short rows rather than a
        /// scrolling list: a scroll view inside a 150pt-tall panel shows four rows and a gutter,
        /// and `ImageRenderer` draws one as empty, which would put this surface beyond the reach
        /// of `FrameDump`. Every preference is on screen at once instead.
        enum Settings {
            static let columnSpacing: CGFloat = 20
            static let groupSpacing: CGFloat = 10
            static let rowSpacing: CGFloat = 2
            /// A row is one line of `Text.caption` with a control beside it. Roughly twice the
            /// height the type needs, because the row *is* the hit target for that control.
            ///
            /// Caption and not `body`, which is what these rows started at. Four columns inside
            /// 584pt leave about 104pt for a label once the switch and its gap are taken out,
            /// and Departure Mono at 11pt spends ~7pt a character — so "Hide when paused",
            /// "Attention ring" and "Replace OS HUD" all rendered with an ellipsis in them.
            /// A truncated preference name is not a shorter preference name, it is a preference
            /// nobody can identify; the type came down instead.
            static let rowHeight: CGFloat = 19
            static let headerSpacing: CGFloat = 4
            /// Between a row's label and the control at its trailing edge. The label truncates
            /// into this gap rather than pushing the controls out of alignment.
            static let labelSpacing: CGFloat = 8

            /// The switch. Small enough to sit on a 19pt row, large enough to read as a switch
            /// and not as a dot: at 10pt tall the knob is 6pt and its travel is 8pt, which is
            /// the smallest offset that still reads as movement rather than as a colour change.
            static let switchWidth: CGFloat = 20
            static let switchHeight: CGFloat = 11
            static let switchKnobInset: CGFloat = 2.5
            static let switchOffFillOpacity: CGFloat = 0.12
            static let switchOnFillOpacity: CGFloat = 0.85
            static let switchBorderOpacity: CGFloat = 0.16

            /// The multi-choice control cycles rather than opening a menu. A pop-up menu is an
            /// AppKit window, and an AppKit window opening out of a `.statusBar`-level panel
            /// that collapses on pointer exit is a fight nobody wins — the menu takes the
            /// pointer, the notch closes, and the menu is left orphaned over the desktop.
            static let choiceMinWidth: CGFloat = 42
            static let choiceHorizontalPadding: CGFloat = 6
            static let choiceCornerRadius: CGFloat = 4
            static let choiceFillOpacity: CGFloat = 0.1

            /// The gear in the panel header, and its hit target. The glyph is 12pt; the target
            /// is not, for the same reason the media transport's is not.
            static let gearGlyphSize: CGFloat = 12
            static let gearHitSize: CGFloat = 22
            static let gearActiveFillOpacity: CGFloat = 0.14

            /// The hide control on a session row. Dim until the row is hovered — it is a
            /// destructive-looking mark sitting next to every session, and at full strength it
            /// competes with the status hue that the row exists to show.
            static let dismissGlyphSize: CGFloat = 8
            static let dismissHitSize: CGFloat = 18
            static let dismissRestingOpacity: CGFloat = 0.25
        }

        enum Agents {
            static let visibleCollapsedSessions = 3
            /// The mascot in the expanded panel — see `AgentActivityGlyph`.
            ///
            /// 30, because the mascot is ten rows tall and the view snaps its cell to a whole
            /// number of points: 30 is where a cell is a full 3pt. That is the size at which a
            /// cell reads as a *block* — the difference between pixel art and a small smooth
            /// icon. The sprite is wider than it is tall, so it draws 36pt across.
            /// Anything from 30 up to 39 renders identically, so this is a floor, not a size.
            ///
            /// It is also 24 rather than 16 because the row no longer draws the agent's own
            /// sprite beside it. The mascot inherited that space, and it needed it: two 16pt
            /// sprites side by side was the "why are there two graphics" the row read as.
            static let activityGlyphSize: CGFloat = 30

            /// The mascot on a collapsed shoulder. One point per cell — the smallest size at
            /// which the figure is still a figure.
            ///
            /// Not `Theme.Metrics.glyphCollapsedSize` (8), which sizes the 8x8 sprites. Feeding
            /// 8 to a 12x12 grid would floor the cell to zero and get clamped back up to 1pt
            /// anyway, so the mark would silently render at 12pt while claiming to be 8 — a
            /// layout that only works by accident.
            ///
            /// 20: ten rows at a 2pt cell, so the pixels stay visible as pixels where the
            /// notch is closed too, and the *whole* creature fits — there is no cropped variant
            /// to keep in sync. Earlier, taller mascots needed 24pt here and rendered their feet
            /// *below* the notch on the desktop, which the filmstrip cannot catch because it is
            /// a collapsed-scenario bug and the filmstrip draws the mark in isolation.
            static let mascotCollapsedSize: CGFloat = 20

            /// How far the pointer must be from a mascot, horizontally and vertically, before
            /// its eyes turn toward it. Smaller than half a row, so each row's blob looks at the
            /// pointer when it is on another row.
            static let mascotGazeReach: CGFloat = 40
            static let mascotGazeRise: CGFloat = 20

            // `statusPulseScale` (1.24), `approvalHaloScale` (1.7) and `approvalHaloLineWidth`
            // (1.5) are gone with the pulsing dot and its static halo. See `StatusIndicator`.
            static let rowIconWidth: CGFloat = 36
            static let rowVerticalPadding: CGFloat = 4
            // `cardCornerRadius` (10) is gone with the rounded rectangle it drew. The
            // approval "card" is the panel — see `ApprovalCardView`.

            static let planLineLimit = 8
            static let elapsedRefreshInterval: TimeInterval = 1

            /// The fade over the bottom of an overflowing session list, and the gap between the
            /// "more below" pill and the panel's bottom edge. The fade is what says "this
            /// continues" before the pill is read; the pill says how much and scrolls to it.
            static let scrollFadeHeight: CGFloat = 26
            static let scrollHintInset: CGFloat = 2

            /// The sleeping mascot that fills the empty panel. 100 is ten rows at a 10pt cell,
            /// which draws the sprite ~120pt wide: big enough to be the panel's subject rather
            /// than a row icon, small enough to leave the provider chips their width.
            static let emptyMascotSize: CGFloat = 100
            /// The column the mascot sits in, so the text beside it starts at a fixed x.
            static let emptyMascotColumnWidth: CGFloat = 136
            /// One provider chip in the empty panel: a name and a connection dot in a
            /// hairline-filled capsule-ish rectangle.
            static let emptyChipHorizontalPadding: CGFloat = 8
            static let emptyChipVerticalPadding: CGFloat = 4
            static let emptyChipCornerRadius: CGFloat = 6
            static let emptyChipSpacing: CGFloat = 6
            static let emptyChipDotSize: CGFloat = 5
            /// How often the empty panel re-checks which agents are open. Only while it is on
            /// screen; a chip lagging a couple of seconds behind an app launch reads as live.
            static let presenceRefreshInterval: TimeInterval = 2

            /// How far a subagent's row is indented under its parent, and how big its mark is.
            ///
            /// The indent is the width of the parent's own mark plus the row gap, so a child
            /// starts exactly where the parent's *text* does: a subagent is something that
            /// session is doing, drawn where the session says what it is doing. The mark is a
            /// little over half the parent's — small enough that a row of them never competes
            /// with the sessions, big enough that the mascot is still a mascot.
            static let subagentIndent: CGFloat = 46
            static let subagentGlyphSize: CGFloat = 18
            /// The most subagents drawn under one session. A swarm can run dozens; the panel
            /// has room for a few, and the rest are counted rather than listed.
            static let visibleSubagents = 3
            /// The dim continuation line under a tool row, as in `└ Done (2 files)`.
            static let subLineIndent: CGFloat = 10
        }
    }

    /// The type scale. Surfaces reference these rather than `Typography` directly, so the
    /// whole app can be re-voiced from one place.
    enum Text {
        static let tradingPrice = Typography.tradingPrice
        static let micro = Typography.micro
        static let caption = Typography.caption
        static let body = Typography.body
        static let title = Typography.title
        static let headline = Typography.headline
    }

    enum Colors {
        static let tradingUp = Color(red: 0.35, green: 0.86, blue: 0.62)
        static let tradingDown = Color(red: 1, green: 0.40, blue: 0.44)
        /// The panel interior. Pure black, so on a real notch the drawn surface and the
        /// physical cutout are indistinguishable — any lift at all reveals the seam.
        static let surface = Color.black

        /// Amber makes the mute key's result visible across both HUD shoulders.
        static let hudMuted = Color(red: 1.0, green: 0.65, blue: 0.18)

        static let textPrimary = Color.white
        static let textSecondary = Color.white.opacity(0.62)
        static let textTertiary = Color.white.opacity(0.38)

        /// Hairline separators inside the panel.
        static let divider = Color.white.opacity(0.1)

        /// The nine agent states, as hues.
        ///
        /// The user set this palette: blue for the two states where work is happening, purple
        /// for the two where the agent is deliberating over its own context, warm for the two
        /// where it is stopped waiting on a person, and green for the two where nothing is
        /// wrong and nothing is wanted. Four families rather than nine colours is the point —
        /// the family is what peripheral vision can actually resolve, and it answers the only
        /// question a glance asks: is it running, is it stuck on me, or is it finished.
        ///
        /// Two pairs share a family, so within each pair the *value* separates them: the state
        /// you are more likely to be waiting on is the brighter one. Hue alone would not have
        /// carried it, which is why the mascot's motion carries the specific verb — see
        /// `AgentActivityGlyph`.
        enum Status {
            /// Blue: the agent is producing something.
            static let working = Color(red: 0.16, green: 0.62, blue: 1.0)
            /// The same blue lifted toward cyan, so a tool call reads as a lighter beat inside
            /// the work rather than as a different kind of activity.
            static let runningTool = Color(red: 0.30, green: 0.88, blue: 1.0)

            /// Lavender: the agent is deliberating rather than producing.
            static let thinking = Color(red: 0.74, green: 0.42, blue: 1.0)
            /// A deeper violet than `thinking`. Compacting is the same family — the agent
            /// working on its own head — but it is a chore rather than a thought, so it sits
            /// below thinking in value instead of competing with it.
            static let compacting = Color(red: 0.55, green: 0.28, blue: 1.0)

            /// Orange: stopped, and it needs a decision from you. The most saturated warm in
            /// the app, because it is the only state that can block an agent indefinitely.
            static let needsApproval = Color(red: 1.0, green: 0.52, blue: 0.08)
            /// Amber: stopped, and it needs an answer. A softer warm than an approval — a
            /// question is a conversation, not a gate.
            static let question = Color(red: 1.0, green: 0.80, blue: 0.10)

            /// Light blue: the turn ended and the next move is yours. Deliberately not warm —
            /// nothing is blocked, the agent simply has nothing left to do.
            static let waitingForInput = Color(red: 0.42, green: 0.84, blue: 1.0)

            /// Green: finished, and worth noticing on the way past.
            static let done = Color(red: 0.22, green: 1.0, blue: 0.45)
            /// The same green drained. Idle is the dimmest thing in the panel on purpose: it
            /// is the row the user is deciding whether to clear, so it must be findable
            /// without ever being the thing their eye lands on first.
            static let idle = Color(red: 0.30, green: 0.72, blue: 0.44)

            /// Media that is currently playing. Deliberately unlike every agent status hue —
            /// the shoulders can hold both at once and they must not be confusable.
            static let playing = Color(red: 0.98, green: 0.45, blue: 0.32)
        }

        // The attention ring's angular gradient used to live here. It is gone rather than
        // retired: an angular gradient sweeps by angle about a centre, and the silhouette it
        // was painting is eight times wider than it is tall, so the band lurched across the
        // long edges and crawled around the short ones. `AttentionRingView` trims the real
        // path instead, which is parameterised by arc length and therefore moves at a constant
        // speed on any shape. Do not reintroduce a gradient sweep here for a "simpler" ring —
        // the shape is the reason it did not work.
    }
}

// MARK: - Liquid notch and attention choreography
//
// Everything the attention moments, the onboarding and the lyric pill move on. These sit in an
// extension rather than in the enums above only because there are a lot of them; the ground
// rule is the same — no surface declares a curve, a duration or a size of its own.

extension Theme.Motion {
    /// An approval taking over the notch. Under-damped on purpose: this is the one opening that
    /// is meant to be *noticed* rather than merely followed, and the overshoot is what reads as
    /// a pop rather than a slide. `open` stays the gesture for everything the pointer asked for.
    static let pop = Animation.spring(response: 0.42, dampingFraction: 0.6, blendDuration: 0)

    /// The notch drawing in a breath just before it pops: 16pt narrower and 3pt shorter, held
    /// for `inhaleHold`. Critically damped, because the inhale is anticipation and anticipation
    /// that wobbles reads as a stutter.
    static let inhale = Animation.spring(response: 0.12, dampingFraction: 1.0, blendDuration: 0)
    static let inhaleHold: Duration = .milliseconds(110)

    /// The first-launch band opening. Longer than `open` because it is also the reveal of
    /// everything that follows, and slightly under-damped so it lands like liquid settling.
    static let band = Animation.spring(response: 0.6, dampingFraction: 0.74, blendDuration: 0)

    /// The bottom edge bulging and the silhouette widening on a nudge — a quick push out and an
    /// under-damped settle. Two curves rather than one spring with an initial velocity because
    /// `withAnimation` has no way to start a spring that is already moving; the push stands in
    /// for the impulse and the settle is what the eye actually reads as the wobble.
    static let kickOut = Animation.easeOut(duration: 0.09)
    static let kickSettle = Animation.spring(response: 0.42, dampingFraction: 0.42, blendDuration: 0)

    /// The shoulders breathing out when a run finishes, and in again. The out is `open`'s
    /// sibling; the in is the critically damped `shoulders` so the silhouette settles without
    /// an overshoot on the way back to rest.
    static let breathOut = Animation.spring(response: 0.38, dampingFraction: 0.72, blendDuration: 0)
    static let breathIn = shoulders


    /// A slower close for the moments where the mascot flies home: its pixels are still in the
    /// air for most of this, and a close as quick as `close` cut them off mid-flight.
    static let homecoming = Animation.timingCurve(0.42, 0.0, 0.22, 1.0, duration: 0.5)
    /// The onboarding band contracting while the mascot's pixels stream to the shoulder.
    static let bandClose = Animation.timingCurve(0.42, 0.0, 0.22, 1.0, duration: 0.6)

    /// Choreography timings. Durations rather than curves, read by `NotchFX` and the scripts
    /// that drive it; the shapes of those motions are the `Liquid` springs below.
    enum Attention {
        /// How long an unanswered takeover waits before it nudges again, and how many times.
        /// A question waits a little longer than a permission because nothing is held open by it.
        static let approvalNudge: Duration = .milliseconds(3600)
        static let questionNudge: Duration = .milliseconds(4000)
        static let maxNudges = 6
        /// Width and bottom-edge push for one nudge, in points.
        static let nudgeWidth: CGFloat = 14
        static let nudgeBelly: CGFloat = 8
        static let popBelly: CGFloat = 13
        /// The inhale before a pop, in points.
        static let inhaleWidth: CGFloat = 16
        static let inhaleHeight: CGFloat = 3

        /// One shock ring leaving the silhouette, and the gap between a pair of them.
        static let ringLife: TimeInterval = 0.75
        static let ringGap: TimeInterval = 0.14
        static let ringReach: CGFloat = 34
        static let sparkCount = 26
        static let rimPulse: TimeInterval = 1.1
        static let rimSweep: TimeInterval = 0.6

        /// The question's drop: how long it takes to form, how long it hangs before the notch
        /// gulps it, and how long a nudge drop lives.
        static let dropForm: Duration = .milliseconds(240)
        static let dropHang: Duration = .milliseconds(520)
        static let nudgeDropLife: TimeInterval = 1.3

        /// The question's drop under the resting notch, and a nudge drop under the open card:
        /// radius and how far below the edge each hangs. Short enough that the neck holds.
        static let questionDrop = (radius: CGFloat(13), hang: CGFloat(17))
        static let nudgeDrop = (radius: CGFloat(10), hang: CGFloat(9))

        /// The onboarding's stream of pixels into a checkbox: how many, one every `streamStagger`,
        /// each in the air for `streamFlight`.
        static let streamCount = 22
        static let streamStagger: TimeInterval = 0.03
        static let streamFlight: TimeInterval = 0.62

        /// The mascot's pixels flying between the shoulder and a card.
        static let transit: TimeInterval = 0.66
        static let transitStagger: TimeInterval = 0.022
        static let transitArrival: Duration = .milliseconds(800)
        static let homecomingArrival: Duration = .milliseconds(880)
        /// The close starts this long after the pixels leave, so they are visibly on their way
        /// before the card closes over the place they came from.
        static let homecomingLead: Duration = .milliseconds(240)

        /// A finished run: how long the shoulders stay breathed out, how far, and how much
        /// confetti.
        static let breathHold: Duration = .milliseconds(1250)
        static let breathWidth: CGFloat = 56
        static let confettiCount = 48
        static let confettiLife: ClosedRange<TimeInterval> = 1.2 ... 1.9

        /// The faint star field behind an attention card. Dim enough to sit behind text.
        static let cardStars = 36
        static let cardStarOpacity: ClosedRange<Double> = 0.12 ... 0.36
    }

    /// The first-launch sequence, beat by beat. Each is the wait *before* the next beat.
    enum Onboarding {
        static let settle: Duration = .milliseconds(600)
        static let melt: Duration = .milliseconds(900)
        static let starsIn: Duration = .milliseconds(800)
        static let gather: Duration = .milliseconds(1350)
        static let lookAround: Duration = .milliseconds(420)
        static let greetLine: Duration = .milliseconds(1100)
        static let greetHold: Duration = .milliseconds(1900)
        static let toConsent: Duration = .milliseconds(340)
        static let connectStream: Duration = .milliseconds(1250)
        static let afterwordHold: Duration = .milliseconds(1800)
        static let toDissolve: Duration = .milliseconds(640)
        static let dissolveLead: Duration = .milliseconds(480)
        static let landing: Duration = .milliseconds(1150)
        static let beforeHint: Duration = .milliseconds(700)
        static let hintDwell: Duration = .milliseconds(2800)
        static let afterHint: Duration = .milliseconds(900)
        /// Characters per second for the typed lines.
        static let typeRate: Double = 30
        static let starCount = 170
    }

    /// The closed-form springs and bezier timings the FX layer evaluates per frame. `Animation`
    /// cannot be sampled, so these are the same physics as numbers: (response, damping) pairs in
    /// SwiftUI's parameterisation, and durations in seconds.
    enum Liquid {
        /// Cubic timing curves as control points: an ease in and out, a fall that accelerates,
        /// and a launch that decelerates. Named for what they do, not for CSS keywords.
        static let glide = (0.45, 0.0, 0.25, 1.0)
        static let accelerate = (0.5, 0.0, 0.75, 0.0)
        static let decelerate = (0.2, 0.8, 0.3, 1.0)
        /// The onboarding mascot's hop: up on `decelerate`, back down on this spring.
        static let hopRise: TimeInterval = 0.12
        static let hopLand = (response: 0.32, damping: 0.45)
        /// The onboarding mascot sliding aside for the consent copy, and back.
        static let mascotSlide = (response: 0.5, damping: 0.82)
        static let dropGrow = (response: 0.35, damping: 0.6)
        static let dropFall: TimeInterval = 0.8
        static let gulp: TimeInterval = 0.35
        static let pillWidth = (response: 0.5, damping: 0.78)
        static let pillGather = (response: 0.5, damping: 0.58)
        static let starSeek: ClosedRange<Double> = 0.45 ... 0.7
        static let starSeekDamping = 0.78
        /// The lyric pill's drop: forming under the notch, falling to the pill, and going home.
        static let pillDripForm: TimeInterval = 0.26
        static let pillDripFall: TimeInterval = 0.42
        static let pillLeave: TimeInterval = 0.45
        /// A new lyric line gliding in.
        static let lineGlide: TimeInterval = 0.42
        /// How long the splashed drops take to drift to a stop, as a drag rate per second.
        static let splashDrag: Double = 2.6
        /// The cursor pushing drops aside while the pill is splashed.
        static let splashPush: Double = 1500
        static let regatherSpread: TimeInterval = 0.28
        static let regatherDelay: TimeInterval = 0.18
    }
}

extension Theme.Metrics {
    /// The band the first launch opens into: wider and taller than the expanded panel, because
    /// it holds a 96pt mascot beside the consent copy.
    static let onboardingBandSize = CGSize(width: 780, height: 250)
    static let onboardingTopCornerRadius: CGFloat = 19
    static let onboardingBottomCornerRadius: CGFloat = 30

    /// The metaball pass that makes drops look like liquid. The blur is what merges two nearby
    /// shapes; the threshold is what gives the merged shape a hard edge again.
    enum Liquid {
        static let blur: CGFloat = 3.5
        static let threshold: Double = 0.42
        /// How far a drop's parent silhouette is drawn inside the real edge, so the drop grows
        /// out from under the crisp notch rather than from its outline.
        static let attachInset: CGFloat = 3
    }

    /// The lyric line floating under the notch.
    enum LyricPill {
        /// From the notch's bottom edge to the pill's centre: the pill's top sits ~13pt under the
        /// notch — far enough to read as its own thing, close enough to read as the notch's.
        static let drop: CGFloat = 24
        static let height: CGFloat = 21
        static let dropCount = 64
        static let horizontalPadding: CGFloat = 22
        static let maxWidth: CGFloat = 560
        /// The smallest a too-long line is scaled to before it is allowed to clip.
        static let minimumScale: CGFloat = 0.8
        static let minWidth: CGFloat = 60
        /// The cursor within this distance of the pill splashes it; beyond `farDistance` it
        /// gathers again. The gap between the two is hysteresis, so a pointer resting at the
        /// edge does not make it flicker.
        static let nearDistance: CGFloat = 30
        static let farDistance: CGFloat = 78
        static let pushRadius: CGFloat = 66
        /// How far a splash throws drops, and how small they shrink to.
        static let splashSpeed: ClosedRange<CGFloat> = 170 ... 420
        static let splashRadius: ClosedRange<CGFloat> = 4 ... 8.5
        /// Drops are kept this far below the notch, so a splash never looks like the notch
        /// leaking.
        static let notchClearance: CGFloat = 12
        static let lineGlideOffset: CGFloat = 9
    }

    /// The approval and question card — `ApprovalCardView`, layout A in
    /// `docs/design/approval-question-layouts-v1.html`.
    enum Prompt {
        /// The left column: who is asking. Wide enough for "NEEDS PERMISSION" at micro size and
        /// a project name, and well clear of the camera housing, so it can start at the top.
        static let whoColumnWidth: CGFloat = 132
        static let columnSpacing: CGFloat = 26
        static let whoTopInset: CGFloat = 16
        static let whoSpacing: CGFloat = 4
        /// Ten rows at a 4pt cell: big enough that the startle and the lean read from across
        /// a desk, which is when this card is being looked at.
        static let mascotSize: CGFloat = 40
        /// With no tab bar above it, the right column starts this far below the housing.
        static let housingClearance: CGFloat = 6
        static let bottomInset: CGFloat = 12
        /// The accent rule down the leading edge, and the gap between it and the mascot.
        static let ruleWidth: CGFloat = 2
        static let ruleGap: CGFloat = 12
        /// The command's code block and the option chips share one fill and corner.
        static let blockCornerRadius: CGFloat = 7
        static let blockFillOpacity: CGFloat = 0.07
        static let blockHorizontalPadding: CGFloat = 10
        static let blockVerticalPadding: CGFloat = 7
        static let commandLineLimit = 3
        /// A warm off-white, so a command reads as code against the card's white prose.
        static let commandTint = Color(red: 0.95, green: 0.82, blue: 0.66)
        static let chipSpacing: CGFloat = 6
        static let chipHorizontalPadding: CGFloat = 8
        static let chipVerticalPadding: CGFloat = 4
        /// Two rows of two. A fifth option and beyond are counted, not drawn.
        static let maxVisibleOptions = 4
        static let tagCornerRadius: CGFloat = 3
        static let tagHorizontalPadding: CGFloat = 4
    }

    /// Where things sit in the onboarding band, in the band's own coordinates. Absolute rather
    /// than stacked, because the effects layer has to know exactly where a checkbox is to
    /// stream pixels into it.
    enum Onboarding {
        static let mascotCenter = CGPoint(x: 390, y: 112)
        static let mascotAsideCenter = CGPoint(x: 132, y: 118)
        static let mascotPixel: CGFloat = 8
        static let greetingTop: CGFloat = 176
        static let consentLeading: CGFloat = 230
        static let titleTop: CGFloat = 46
        static let bodyTop: CGFloat = 74
        static let bodyLineSpacing: CGFloat = 3
        static let rowsTop: CGFloat = 116
        static let rowHeight: CGFloat = 20
        static let checkboxSize: CGFloat = 12
        static let checkboxCornerRadius: CGFloat = 3
        static let nameColumn: CGFloat = 130
        static let buttonsTop: CGFloat = 204
        /// Every detected agent gets a row — the user has to be able to untick any agent the
        /// yes would apply to. Past `singleColumnRows` they split into two columns of this
        /// width, with a narrower name and a status that truncates in the middle.
        static let singleColumnRows = 3
        static let columnWidth: CGFloat = 270
        static let compactNameColumn: CGFloat = 112
        static let compactStatusWidth: CGFloat = 140
        /// The intro's question drop and the stars, in the band.
        static let starInset = CGSize(width: 6, height: 6)
    }

    enum Attention {
        static let sparkSize: ClosedRange<CGFloat> = 2 ... 3.4
        static let sparkSpeed: ClosedRange<CGFloat> = 140 ... 340
        static let confettiSize: ClosedRange<CGFloat> = 3 ... 5
        static let confettiGravity: CGFloat = 520
        static let ringWidth: CGFloat = 2.4
        static let rimWidth: CGFloat = 3
    }
}

extension Theme.Colors {
    /// The onboarding mascot and its stars: a warm white, so the first thing the app shows is
    /// not yet any of the status hues it will later use to mean something.
    static let ink = Color(red: 0.95, green: 0.94, blue: 0.91)
    static let starTints: [Color] = [ink, ink, Status.working, Status.needsApproval, Status.thinking]
    static let confetti: [Color] = [Status.done, Status.done, ink, Status.working, Status.question]
}
