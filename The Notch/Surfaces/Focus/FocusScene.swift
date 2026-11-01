import SwiftUI

/// The focus timer's mascot and the little desk it works at, as a grid of cells.
///
/// The creature is the agent mascot — `AgentActivityGlyph.Posed` posed, not a lookalike — so
/// the app has one character. What focus adds is around it: a keyboard its paws tap, a monitor
/// that fills with code one character per keystroke, a mug on breaks. Typing has to *read* as
/// typing at 6pt a cell, and a paw going down is not enough on its own; the key lighting under
/// it, the antenna flicking on the same beat and the text appearing on the screen are what
/// make it unmistakable. See `docs/design/pomodoro-ui-v4.html`.
///
/// The body also fills with colour as the phase goes on, bottom up with a little jitter — the
/// "ripening" from `pomodoro-ui-v2.html` — while its outline stays lit, so the creature is
/// always all there and only how *full* it is changes.
@MainActor
enum FocusScene {
    static let columns = 24
    static let rows = 14

    enum Mode: Equatable {
        /// Before Start. `ruler` is which ruler is being dragged, if one is.
        case ready(ruler: Ruler?)
        /// Between phases with auto-start off: standing beside the desk, waiting for the go.
        case waiting
        case hop
        case typing(rush: Bool)
        case done
        case tea
        case nap
        case paused
    }

    enum Ruler: Equatable { case focus, rest }

    /// - Parameters:
    ///   - time: seconds on a free-running clock, for the loops (blinks, steam, Z's).
    ///   - phaseTime: seconds since this mode began, for the one-shots (the hop, the cheer).
    ///   - typed: seconds of focus elapsed in this round. Drives the keystrokes, so the code on
    ///     screen freezes where it was when the timer is paused.
    static func cells(
        mode: Mode,
        time: Double,
        phaseTime: Double,
        typed: Double,
        fill: Double
    ) -> [AgentActivityGlyph.Cell] {
        var out: [AgentActivityGlyph.Cell] = []
        let standing = mode == .waiting || mode == .hop || { if case .ready = mode { true } else { false } }()
        let originX = standing ? 6 : 1
        let originY = 3

        var figure = AgentActivityGlyph.Posed()
        var bodyFill = 1.0
        var paws: (down: Side?, shown: Bool) = (nil, false)
        var pressedKey: Int?
        var strokes = 0
        var thinking = false
        var sipping = false
        let blink = (time + 0.37).truncatingRemainder(dividingBy: 4.3) < 0.13

        switch mode {
        case let .ready(ruler):
            if let ruler {
                let beat = Int(time * 8) % 2 == 0
                figure.eyeShift = 1
                figure.eyeLift = ruler == .focus ? -1 : 1
                figure.antennaLeft = beat ? 2 : 1
                figure.antennaRight = beat ? 1 : 2
                figure.legs = Int(time * 6) % 2
            } else {
                idle(&figure, time: time, blink: blink)
            }
        case .waiting:
            idle(&figure, time: time, blink: blink)
            figure.eyeShift = 1
        case .hop:
            let t = phaseTime
            figure.antennaLeft = 2
            figure.antennaRight = 2
            figure.eyes = .wide
            if t < 0.12 {
                figure.squashed = true
                figure.eyes = .narrow
            } else if t < 0.5 {
                figure.bob = -2
                figure.legs = 1
            } else if t < 0.62 {
                figure.squashed = true
            }
        case let .typing(rush):
            let beat = rush ? 0.1 : 0.2
            let cycle = 5.0
            let work = 4.1
            let inCycle = typed.truncatingRemainder(dividingBy: cycle)
            thinking = !rush && inCycle > work
            strokes = Int(typed / cycle) * Int(work / beat) + Int(min(inCycle, work) / beat)
            let n = Int(typed / beat)
            let down = !thinking && typed.truncatingRemainder(dividingBy: beat) < beat * 0.55
            let left = n % 2 == 0
            figure.legs = nil
            figure.eyes = rush ? .wide : .narrow
            figure.eyeShift = 1
            figure.antennaLeft = left && down ? 2 : 1
            figure.antennaRight = !left && down ? 2 : 1
            if thinking {
                figure.eyes = .open
                figure.eyeLift = -1
                figure.antennaLeft = 1
                figure.antennaRight = (time * 1.3).truncatingRemainder(dividingBy: 1) < 0.5 ? 2 : 1
            } else if !rush, blink {
                figure.eyes = .closed
            }
            if rush {
                figure.antennaLeft = 2
                figure.antennaRight = 2
            }
            bodyFill = fill
            paws = (down ? (left ? .left : .right) : nil, true)
            if down { pressedKey = left ? 2 + (n * 3) % 4 : 8 + (n * 5) % 4 }
        case .done:
            let t = phaseTime
            figure.legs = nil
            figure.eyes = .narrow
            figure.antennaLeft = 2
            figure.antennaRight = 2
            if t < 1.3, t.truncatingRemainder(dividingBy: 0.62) < 0.32 {
                figure.bob = -2
            } else if t >= 1.3 {
                let wag = Int(t * 3) % 2 == 0
                figure.antennaLeft = wag ? 2 : 1
                figure.antennaRight = wag ? 1 : 2
            }
            paws = (nil, true)
        case .tea:
            let cycle = time.truncatingRemainder(dividingBy: 5.5)
            sipping = cycle > 4.2 && cycle < 5.1
            let wag = Int(time / 1.4) % 2 == 0
            figure.legs = nil
            figure.eyes = sipping ? .closed : .narrow
            figure.lean = sipping ? 1 : 0
            figure.antennaLeft = wag ? 2 : 1
            figure.antennaRight = wag ? 1 : 2
            bodyFill = fill
            paws = (nil, true)
        case .nap:
            figure.legs = nil
            figure.squashed = true
            figure.eyes = .asleep
            figure.antennaLeft = 0
            figure.antennaRight = 0
            figure.brightness = 0.78 + 0.22 * sin(time * 2.2)
            bodyFill = fill
            paws = (nil, true)
        case .paused:
            figure.legs = nil
            bodyFill = fill
            figure.brightness = Theme.Metrics.Focus.pausedBrightness
            paws = (nil, true)
        }

        let desk = !standing
        if desk {
            furniture(into: &out, mode: mode, time: time, strokes: strokes, thinking: thinking,
                      pressedKey: pressedKey, sipping: sipping)
        }

        // The creature, then the fill, then its paws on the keys.
        let dim = mode == .paused ? Theme.Metrics.Focus.pausedBrightness : 1
        let creature = filled(
            AgentActivityGlyph.cells(for: figure, headroom: AgentActivityGlyph.headroom),
            figure: figure,
            fill: bodyFill
        )
        for cell in creature {
            out.append(cell.moved(by: originX, originY))
        }
        if paws.shown {
            for side in [Side.left, .right] {
                let row = paws.down == side ? 12 : 11
                for column in side.columns {
                    out.append(.init(column: column + originX + figure.lean, row: row, alpha: dim, tone: .shadow))
                }
            }
        }

        effects(into: &out, mode: mode, time: time, phaseTime: phaseTime,
                head: (originX + figure.lean, originY + figure.bob))
        return out.filter { (0 ..< columns).contains($0.column) && (0 ..< rows).contains($0.row) }
    }

    /// The figure alone, filled — what the collapsed shoulder draws.
    static func shoulderCells(figure: AgentActivityGlyph.Posed, fill: Double) -> [AgentActivityGlyph.Cell] {
        filled(AgentActivityGlyph.cells(for: figure, headroom: 0), figure: figure, fill: fill)
    }

    // MARK: Ripening

    /// Leaves the first `fill` of the body lit and turns the rest into a faint ghost of itself,
    /// outline brighter than the inside so the silhouette never breaks up. Eyes that fall in
    /// the unlit part become faint white instead of holes, which on a ghost would vanish.
    static func filled(
        _ cells: [AgentActivityGlyph.Cell],
        figure: AgentActivityGlyph.Posed,
        fill: Double
    ) -> [AgentActivityGlyph.Cell] {
        guard fill < 1 else { return cells }
        let spans = AgentActivityGlyph.bodySpans(squashed: figure.squashed)
        let order = fillOrder(spans: spans)
        let lit = Set(order.prefix(Int((Double(order.count) * max(0, fill)).rounded())))
        var byPoint: [Point: AgentActivityGlyph.Cell] = [:]
        for cell in cells { byPoint[Point(cell.column, cell.row)] = cell }
        var out = cells.filter { cell in
            let local = Point(cell.column - figure.lean, cell.row - figure.bob)
            return !spans.contains { $0.row == local.row && $0.columns.contains(local.column) }
        }
        for span in spans {
            for column in span.columns {
                let local = Point(column, span.row)
                let placed = Point(column + figure.lean, span.row + figure.bob)
                let isLit = lit.contains(local)
                guard let cell = byPoint[placed] else {
                    // An eye hole.
                    if !isLit {
                        out.append(.init(column: placed.column, row: placed.row,
                                         alpha: Theme.Metrics.Focus.ghostEyeAlpha, tone: .flat(.white)))
                    }
                    continue
                }
                if isLit || cell.tone == .white {
                    out.append(cell)
                } else {
                    let edge = column == span.columns.lowerBound || column == span.columns.upperBound
                        || cell.tone == .highlight || cell.tone == .shadow
                    out.append(.init(column: cell.column, row: cell.row,
                                     alpha: cell.alpha * (edge ? Theme.Metrics.Focus.ghostEdgeAlpha : Theme.Metrics.Focus.ghostAlpha),
                                     tone: .body))
                }
            }
        }
        return out
    }

    /// Bottom row first, with a fixed per-cell jitter so the fill rises unevenly, like
    /// something filling up rather than a bar.
    private static func fillOrder(spans: [(row: Int, columns: ClosedRange<Int>)]) -> [Point] {
        spans.flatMap { span in span.columns.map { Point($0, span.row) } }
            .sorted { rank($0) < rank($1) }
    }

    private static func rank(_ point: Point) -> Double {
        let hash = (point.column &* 73_856_093) ^ (point.row &* 19_349_663)
        return -Double(point.row) + Double(abs(hash) % 1000) / 1000 * 1.4
    }

    // MARK: Furniture

    /// Desk edge, keyboard, monitor and mug. Flat: scenery never glows.
    private static func furniture(
        into out: inout [AgentActivityGlyph.Cell],
        mode: Mode,
        time: Double,
        strokes: Int,
        thinking: Bool,
        pressedKey: Int?,
        sipping: Bool
    ) {
        func prop(_ column: Int, _ row: Int, _ alpha: Double) {
            out.append(.init(column: column, row: row, alpha: alpha, tone: .flat(.white)))
        }
        for column in 0 ..< columns { prop(column, 13, 0.16) }
        for column in 1 ... 12 {
            if column == pressedKey {
                out.append(.init(column: column, row: 12, alpha: 1, tone: .white))
            } else {
                prop(column, 12, column % 2 == 1 ? 0.30 : 0.22)
            }
        }
        // The monitor: frame, stand, base.
        for column in 14 ... 22 { prop(column, 3, 0.32); prop(column, 10, 0.32) }
        for row in 4 ... 9 { prop(14, row, 0.32); prop(22, row, 0.32) }
        prop(18, 11, 0.25)
        for column in 16 ... 20 { prop(column, 12, 0.2) }

        let screen = (columns: 15 ... 21, rows: 4 ... 9)
        let resting = mode == .tea || mode == .nap
        for row in screen.rows {
            for column in screen.columns {
                out.append(.init(column: column, row: row, alpha: resting ? 0.03 : 0.07, tone: .body))
            }
        }

        switch mode {
        case .typing, .paused:
            code(into: &out, strokes: strokes, screen: screen,
                 cursor: mode != .paused && (!thinking || time.truncatingRemainder(dividingBy: 1) < 0.5))
            if mode == .paused {
                for row in 5 ... 8 {
                    out.append(.init(column: 17, row: row, alpha: 0.85, tone: .white))
                    out.append(.init(column: 19, row: row, alpha: 0.85, tone: .white))
                }
            }
        case .done:
            for (column, row) in [(15, 6), (16, 7), (17, 8), (18, 7), (19, 6), (20, 5), (21, 4)] {
                out.append(.init(column: column, row: row, alpha: 1, tone: .white))
            }
        case .nap:
            // A screensaver pixel bouncing about the dark screen.
            let step = Int(time * 3)
            let column = screen.columns.lowerBound + abs(step % 12 - 6)
            let row = screen.rows.lowerBound + abs((step / 2) % 10 - 5)
            out.append(.init(column: min(column, screen.columns.upperBound),
                             row: min(row, screen.rows.upperBound), alpha: 0.7, tone: .body))
        case .tea:
            out.append(.init(column: 21, row: 9, alpha: 0.8, tone: .body))
            // The mug, on the desk between the keyboard and the monitor, with steam.
            let lift = sipping ? 0 : 1
            for (column, row) in [(13, 10), (14, 10), (13, 11), (14, 11)] {
                prop(column, row + lift, 0.85)
            }
            prop(15, 10 + lift, 0.5)
            let puff = Int(time * 2.2) % 3
            prop(13, 9 - puff + lift, 0.35)
            prop(14, 8 - (puff + 1) % 3 + lift, 0.25)
        default:
            break
        }
    }

    /// Lines of "code" laid out from a keystroke count, the last six visible, with the cursor.
    private static func code(
        into out: inout [AgentActivityGlyph.Cell],
        strokes: Int,
        screen: (columns: ClosedRange<Int>, rows: ClosedRange<Int>),
        cursor: Bool
    ) {
        var lines: [(indent: Int, length: Int, current: Bool)] = []
        var left = strokes
        var index = 0
        while true {
            let (indent, length) = codeShape[index % codeShape.count]
            if left <= length {
                lines.append((indent, left, true))
                break
            }
            lines.append((indent, length, false))
            left -= length
            index += 1
        }
        let visible = lines.suffix(screen.rows.count)
        for (offset, line) in visible.enumerated() {
            let row = screen.rows.lowerBound + offset
            for character in 0 ..< line.length {
                let column = screen.columns.lowerBound + line.indent + character
                let isKeyword = character == 0 && line.indent == 0
                out.append(.init(column: column, row: row,
                                 alpha: character % 3 == 2 ? 0.55 : 1,
                                 tone: isKeyword ? .highlight : .body))
            }
            if line.current, cursor {
                out.append(.init(column: screen.columns.lowerBound + line.indent + line.length,
                                 row: row, alpha: 1, tone: .white))
            }
        }
    }

    /// Indent and length of each line, repeating. Lengths fit the 7-cell screen.
    private static let codeShape = [
        (0, 4), (1, 3), (1, 5), (2, 2), (1, 4), (0, 2), (0, 5),
        (1, 3), (2, 3), (1, 2), (0, 3), (0, 6), (1, 4), (1, 2),
    ]

    // MARK: Effects

    private static func effects(
        into out: inout [AgentActivityGlyph.Cell],
        mode: Mode,
        time: Double,
        phaseTime: Double,
        head: (column: Int, row: Int)
    ) {
        switch mode {
        case .done where phaseTime < 2.8:
            let colours = Theme.Colors.Focus.confetti
            for index in 0 ..< 14 {
                let drift = Int(phaseTime * 2) * (index % 3 - 1)
                let column = ((index * 7 + 3 + drift) % columns + columns) % columns
                let row = Int((phaseTime * 7 + Double(index) * 2.3).truncatingRemainder(dividingBy: Double(rows)))
                out.append(.init(column: column, row: row, alpha: 0.95, tone: .accent(colours[index % colours.count])))
            }
        case .nap:
            for index in 0 ..< 3 {
                let phase = (time * 1.1 + Double(index) * 1.4).truncatingRemainder(dividingBy: 4.2)
                out.append(.init(column: head.column + 11 + index, row: head.row + 2 - Int(phase),
                                 alpha: max(0, 0.75 - phase * 0.17), tone: .white))
            }
        case .paused:
            let lit = Int(time * 3) % 4
            for (index, column) in [4, 6, 8].enumerated() {
                out.append(.init(column: head.column + column, row: head.row - 1,
                                 alpha: index < lit ? 0.95 : 0.22, tone: .white))
            }
        case .typing(rush: true) where time.truncatingRemainder(dividingBy: 1) < 0.25:
            out.append(.init(column: head.column + 2, row: head.row, alpha: 0.9, tone: .white))
            out.append(.init(column: head.column + 9, row: head.row, alpha: 0.9, tone: .white))
        default:
            break
        }
    }

    // MARK: Helpers

    private static func idle(_ figure: inout AgentActivityGlyph.Posed, time: Double, blink: Bool) {
        let phase = time.truncatingRemainder(dividingBy: 8)
        if phase > 3, phase < 4.3 { figure.eyeShift = -1 } else if phase > 5, phase < 6.3 { figure.eyeShift = 1 }
        if phase > 6.7, phase < 6.95 {
            figure.bob = -1
            figure.legs = 1
            figure.antennaLeft = 2
            figure.antennaRight = 2
        }
        if blink { figure.eyes = .closed }
    }

    private enum Side {
        case left, right

        /// Paw columns in the creature's own grid, under its left and right halves.
        var columns: [Int] { self == .left ? [3, 4] : [7, 8] }
    }

    private struct Point: Hashable {
        let column: Int
        let row: Int
        init(_ column: Int, _ row: Int) {
            self.column = column
            self.row = row
        }
    }
}

private extension AgentActivityGlyph.Cell {
    func moved(by columns: Int, _ rows: Int) -> Self {
        .init(column: column + columns, row: row + rows, alpha: alpha, tone: tone)
    }
}
