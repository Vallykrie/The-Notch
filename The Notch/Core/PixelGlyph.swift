import SwiftUI

/// An 8x8 sprite, one bit per pixel, MSB is the leftmost column.
///
/// The notch is trim on a piece of hardware, and SF Symbols make it read as a system dialog
/// that wandered up there. Sprites on a pixel grid sit with Departure Mono instead of fighting
/// it. These are drawn here rather than shipped as PNGs so they inherit `foregroundStyle` and
/// stay crisp at any scale factor — a bitmap asset would resample and blur.
///
/// All artwork below is original.
nonisolated struct PixelGlyph: Equatable, Sendable {
    /// Top row first.
    let rows: [UInt8]

    static let side = 8

    // MARK: Agents

    /// Eight-point burst.
    static let claude = PixelGlyph(rows: [
        0b0001_1000,
        0b0001_1000,
        0b0101_1010,
        0b0011_1100,
        0b0011_1100,
        0b0101_1010,
        0b0001_1000,
        0b0001_1000,
    ])

    /// Chevron over a prompt underscore.
    static let codex = PixelGlyph(rows: [
        0b0000_0000,
        0b1100_0000,
        0b0110_0000,
        0b0011_0000,
        0b0110_0000,
        0b1100_0000,
        0b0000_0000,
        0b0001_1111,
    ])

    /// Four-point sparkle.
    static let gemini = PixelGlyph(rows: [
        0b0001_0000,
        0b0001_0000,
        0b0011_1000,
        0b1111_1110,
        0b0011_1000,
        0b0001_0000,
        0b0001_0000,
        0b0000_0000,
    ])

    /// Arrow pointer.
    static let cursor = PixelGlyph(rows: [
        0b1000_0000,
        0b1100_0000,
        0b1110_0000,
        0b1111_0000,
        0b1111_1000,
        0b1110_0000,
        0b1011_0000,
        0b0001_1000,
    ])

    /// Generic agent: a chip with pins.
    static let chip = PixelGlyph(rows: [
        0b0010_0100,
        0b0111_1110,
        0b1101_1011,
        0b0111_1110,
        0b0111_1110,
        0b1101_1011,
        0b0111_1110,
        0b0010_0100,
    ])

    // MARK: System surfaces

    /// Bound calendar page.
    static let calendar = PixelGlyph(rows: [
        0b0010_0100,
        0b0111_1110,
        0b0100_0010,
        0b0111_1110,
        0b0100_0010,
        0b0100_0010,
        0b0111_1110,
        0b0000_0000,
    ])

    /// Bound calendar page with an exclamation mark in its body.
    static let calendarWarning = PixelGlyph(rows: [
        0b0010_0100,
        0b0111_1110,
        0b0100_0010,
        0b0111_1110,
        0b0101_1010,
        0b0101_1010,
        0b0100_0010,
        0b0111_1010,
    ])

    /// Map pin.
    static let location = PixelGlyph(rows: [
        0b0001_1000,
        0b0011_1100,
        0b0110_0110,
        0b0110_0110,
        0b0011_1100,
        0b0001_1000,
        0b0001_1000,
        0b0000_0000,
    ])

    /// Lightning mark for a battery connected to power.
    static let bolt = PixelGlyph(rows: [
        0b0001_1000,
        0b0011_0000,
        0b0110_0000,
        0b1111_1100,
        0b0001_1000,
        0b0011_0000,
        0b0110_0000,
        0b0000_0000,
    ])

    // MARK: System HUD

    /// Speaker cone with two arcs of sound.
    ///
    /// The cone is deliberately only four columns wide. A five-column cone leaves one column
    /// for the waves, which at 8pt renders as a single stray dot that reads as dirt on the
    /// display rather than as sound.
    static let speaker = PixelGlyph(rows: [
        0b0001_0000,
        0b0011_0000,
        0b0111_0010,
        0b1111_0101,
        0b1111_0101,
        0b0111_0010,
        0b0011_0000,
        0b0001_0000,
    ])

    /// The same cone with a cross where the arcs were.
    ///
    /// Muting swaps the sprite rather than tinting it: at 8pt the sprite is the only element
    /// with enough ink to carry a state, and colour on the collapsed surface already means
    /// agent status. The cross is 3x3 against a cone whose axis sits on the half-pixel, so it
    /// rides one half-pixel high — which is invisible, and the alternative (a 4x4 cross) has to
    /// start at column 4 and collides with the cone's mouth on the outer rows.
    static let speakerMuted = PixelGlyph(rows: [
        0b0001_0000,
        0b0011_0000,
        0b0111_0101,
        0b1111_0010,
        0b1111_0101,
        0b0111_0000,
        0b0011_0000,
        0b0001_0000,
    ])

    /// Sun: an octagonal disc with eight detached rays.
    ///
    /// The rays are separated from the disc by a blank ring. Rays that touch the disc fill the
    /// sprite's whole 8x8 field with lit pixels and the result reads as a blob, not a sun.
    static let brightness = PixelGlyph(rows: [
        0b0001_1000,
        0b0100_0010,
        0b0001_1000,
        0b1011_1101,
        0b1011_1101,
        0b0001_1000,
        0b0100_0010,
        0b0001_1000,
    ])

    // MARK: Chrome

    /// Cog: a hollow body with four teeth on the axes and four bulges on the diagonals.
    ///
    /// The hole is only 2x2. A 4x4 hole leaves a one-pixel rim, and a one-pixel rim on a black
    /// surface reads as a broken circle rather than as a gear.
    static let gear = PixelGlyph(rows: [
        0b0011_1100,
        0b0111_1110,
        0b1111_1111,
        0b1110_0111,
        0b1110_0111,
        0b1111_1111,
        0b0111_1110,
        0b0011_1100,
    ])

    /// Minus sign — dismiss, in the "put this away" sense rather than the "delete it" sense.
    ///
    /// Deliberately not ``cross``. A cross next to a running agent session reads as *kill the
    /// agent*, which is not what the control does: hiding a session removes it from the panel
    /// and nothing else, and the session reappears the moment it emits another event.
    static let minus = PixelGlyph(rows: [
        0b0000_0000,
        0b0000_0000,
        0b0000_0000,
        0b0111_1110,
        0b0111_1110,
        0b0000_0000,
        0b0000_0000,
        0b0000_0000,
    ])

    /// An arrow out of the corner — bring this session's window forward. The arrow rather than
    /// a window outline because at 8x8 a window is a square, and a square says nothing.
    static let openWindow = PixelGlyph(rows: [
        0b0000_0000,
        0b0001_1110,
        0b0000_0110,
        0b0000_1010,
        0b0001_0010,
        0b0010_0000,
        0b0100_0000,
        0b0000_0000,
    ])

    // MARK: Media

    /// Right-pointing play mark.
    // Two pixels wider per row, 1 → 3 → 5 → 6, so the sides keep one slope to the tip. The old
    // shape stepped 2 → 4 → 5 → 5: a square shoulder that read as a flag, or a "P". It sits a
    // column right of the grid's centre because a triangle's weight is near its flat side;
    // centred by bounding box, it looks pushed left inside the round button.
    static let play = PixelGlyph(rows: [
        0b0000_0000,
        0b0010_0000,
        0b0011_1000,
        0b0011_1110,
        0b0011_1111,
        0b0011_1110,
        0b0011_1000,
        0b0010_0000,
    ])

    /// Two-column pause mark.
    static let pause = PixelGlyph(rows: [
        0b0000_0000,
        0b0110_0110,
        0b0110_0110,
        0b0110_0110,
        0b0110_0110,
        0b0110_0110,
        0b0110_0110,
        0b0000_0000,
    ])

    /// Eighth note with a filled head.
    static let musicNote = PixelGlyph(rows: [
        0b0001_1000,
        0b0001_1110,
        0b0001_1010,
        0b0001_1000,
        0b0001_1000,
        0b0011_1000,
        0b0111_1000,
        0b0011_0000,
    ])

    /// Double left-pointing skip mark.
    // Solid, like every other transport glyph. The hollow triangles collapsed into crossed
    // lines at 8x8 and the pair read as bow-ties (⋈) rather than as skip.
    static let skipBack = PixelGlyph(rows: [
        0b0000_0000,
        0b1000_1001,
        0b1001_1011,
        0b1011_1111,
        0b1011_1111,
        0b1001_1011,
        0b1000_1001,
        0b0000_0000,
    ])

    /// Double right-pointing skip mark.
    static let skipForward = PixelGlyph(rows: [
        0b0000_0000,
        0b1001_0001,
        0b1101_1001,
        0b1111_1101,
        0b1111_1101,
        0b1101_1001,
        0b1001_0001,
        0b0000_0000,
    ])

    /// Crossing shuffle paths with arrowheads.
    static let shuffle = PixelGlyph(rows: [
        0b0000_0010,
        0b1100_0111,
        0b0010_1010,
        0b0001_1000,
        0b0001_1000,
        0b0010_1010,
        0b1100_0111,
        0b0000_0010,
    ])

    /// Three lines of text, shortening — lyrics. Drawn as text rather than as a note because
    /// the note already means "a player" on the source badge and the launch buttons.
    static let lyrics = PixelGlyph(rows: [
        0b0000_0000,
        0b0111_1110,
        0b0000_0000,
        0b0111_1100,
        0b0000_0000,
        0b0111_0000,
        0b0000_0000,
        0b0000_0000,
    ])

    /// Looping track path with a corner arrow.
    static let repeatTrack = PixelGlyph(rows: [
        0b0000_0000,
        0b0011_1100,
        0b0100_0010,
        0b0100_0010,
        0b0100_0010,
        0b0100_0100,
        0b0011_1110,
        0b0000_0100,
    ])

    /// Hollow heart.
    static let heart = PixelGlyph(rows: [
        0b0110_0110,
        0b1001_1001,
        0b1000_0001,
        0b0100_0010,
        0b0010_0100,
        0b0001_1000,
        0b0000_0000,
        0b0000_0000,
    ])

    /// Filled heart.
    static let heartFilled = PixelGlyph(rows: [
        0b0110_0110,
        0b1111_1111,
        0b1111_1111,
        0b0111_1110,
        0b0011_1100,
        0b0001_1000,
        0b0000_0000,
        0b0000_0000,
    ])

    // MARK: Session state

    /// Waiting on an answer.
    static let question = PixelGlyph(rows: [
        0b0011_1100,
        0b0110_0110,
        0b0000_0110,
        0b0000_1100,
        0b0001_1000,
        0b0000_0000,
        0b0001_1000,
        0b0000_0000,
    ])

    /// Needs approval.
    static let bang = PixelGlyph(rows: [
        0b0001_1000,
        0b0001_1000,
        0b0001_1000,
        0b0001_1000,
        0b0001_1000,
        0b0000_0000,
        0b0001_1000,
        0b0000_0000,
    ])

    /// Finished.
    static let check = PixelGlyph(rows: [
        0b0000_0000,
        0b0000_0010,
        0b0000_0110,
        0b0000_1100,
        0b1101_1000,
        0b0111_0000,
        0b0010_0000,
        0b0000_0000,
    ])

    /// Ended without finishing.
    static let cross = PixelGlyph(rows: [
        0b0000_0000,
        0b0100_0010,
        0b0110_0110,
        0b0011_1100,
        0b0011_1100,
        0b0110_0110,
        0b0100_0010,
        0b0000_0000,
    ])

    func isOn(row: Int, column: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        return rows[row] & (0b1000_0000 >> UInt8(column)) != 0
    }
}

/// Renders a `PixelGlyph` at a size snapped to whole pixels.
struct PixelGlyphView: View {
    let glyph: PixelGlyph
    /// Nominal side length. The drawn size is rounded down to the nearest multiple of 8 so
    /// every sprite pixel lands on an integer number of points and no row is half-lit.
    var side: CGFloat = 8
    /// Most sprites are decoration inside a labelled row. A standalone sprite can opt into
    /// accessibility with the semantic name its image-based predecessor carried.
    var accessibilityLabel: String? = nil

    private var pixel: CGFloat {
        max(1, (side / CGFloat(PixelGlyph.side)).rounded(.down))
    }

    private var drawnSide: CGFloat {
        pixel * CGFloat(PixelGlyph.side)
    }

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, _ in
            for row in 0 ..< PixelGlyph.side {
                for column in 0 ..< PixelGlyph.side where glyph.isOn(row: row, column: column) {
                    context.fill(
                        Path(
                            CGRect(
                                x: CGFloat(column) * pixel,
                                y: CGFloat(row) * pixel,
                                width: pixel,
                                height: pixel
                            )
                        ),
                        with: .style(.foreground)
                    )
                }
            }
        }
        .frame(width: drawnSide, height: drawnSide)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel ?? ""))
        .accessibilityHidden(accessibilityLabel == nil)
    }
}

#Preview {
    HStack(spacing: 12) {
        PixelGlyphView(glyph: .claude, side: 16)
        PixelGlyphView(glyph: .codex, side: 16)
        PixelGlyphView(glyph: .gemini, side: 16)
        PixelGlyphView(glyph: .cursor, side: 16)
        PixelGlyphView(glyph: .chip, side: 16)
        PixelGlyphView(glyph: .calendar, side: 16)
        PixelGlyphView(glyph: .calendarWarning, side: 16)
        PixelGlyphView(glyph: .location, side: 16)
        PixelGlyphView(glyph: .bolt, side: 16)
        PixelGlyphView(glyph: .play, side: 16)
        PixelGlyphView(glyph: .pause, side: 16)
        PixelGlyphView(glyph: .question, side: 16)
        PixelGlyphView(glyph: .bang, side: 16)
        PixelGlyphView(glyph: .check, side: 16)
        PixelGlyphView(glyph: .cross, side: 16)
    }
    .foregroundStyle(.white)
    .padding()
    .background(.black)
}
