import AppKit
import SwiftUI

/// One half of the sung line on the collapsed notch.
///
/// The line is split at the word that best balances the two halves, and the halves sit either
/// side of the camera housing — the first right-aligned against the housing's left edge, the
/// second left-aligned from its right — so the eye reads straight across the hardware the way
/// it reads across a gutter. The alternative, the whole line on one shoulder, needed one
/// shoulder twice as wide, and shoulders have to stay symmetric (see
/// `NotchCoordinator.collapsedSize`), so the other side would have been a slab of black.
///
/// The shoulders are sized to the line — see `shoulderWidth(for:)` — so a short line gets a
/// narrow notch and the silhouette breathes with the song.
@MainActor
struct LyricsCollapsedView: View {
    enum Half { case leading, trailing }

    @ObservedObject var lyrics: LyricsController
    let half: Half

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let index = lyrics.currentLineIndex
        ZStack(alignment: half == .leading ? .trailing : .leading) {
            Text(text)
                .font(Theme.Text.caption)
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(Theme.Metrics.LiveActivity.lyricsMinimumScale)
                // A new line rises into place as the old one lifts away — the reel's motion,
                // one row tall.
                .id(index ?? -1)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
        }
        // The shoulder frames its content with `.leading` alignment; claiming the full width
        // is what lets each half hug the camera housing instead of the outer edge.
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: half == .leading ? .trailing : .leading)
        .clipped()
        // The same spring that resizes the silhouette for the new line, so the text and the
        // notch around it move as one.
        .animation(reduceMotion ? nil : Theme.Motion.shoulders, value: index)
        .accessibilityHidden(half == .trailing)
        .accessibilityLabel(half == .leading ? (lyrics.currentLine ?? "") : "")
    }

    private var text: String {
        let (first, second) = Self.halves(of: lyrics.currentLine)
        return half == .leading ? first : second
    }

    /// The two halves shown for `line`. No line yet (the intro) or a stamped blank line (an
    /// instrumental break) shows a note on the leading side.
    static func halves(of line: String?) -> (String, String) {
        guard let line, !line.isEmpty else { return ("♪", "") }
        return split(line)
    }

    /// Splits at the space that makes the halves closest in length. One word stays whole on
    /// the leading side.
    static func split(_ line: String) -> (String, String) {
        let words = line.split(separator: " ").map(String.init)
        guard words.count > 1 else { return (line, "") }
        var best = 1
        var bestDifference = Int.max
        for cut in 1 ..< words.count {
            let left = words[..<cut].joined(separator: " ").count
            let right = words[cut...].joined(separator: " ").count
            if abs(left - right) < bestDifference {
                bestDifference = abs(left - right)
                best = cut
            }
        }
        return (words[..<best].joined(separator: " "), words[best...].joined(separator: " "))
    }

    /// The shoulder width that fits `line`: the longer half at caption size, plus the shoulder's
    /// outer padding and housing inset, clamped between the theme's floor and ceiling. Past the
    /// ceiling the text scales down instead (`lyricsMinimumScale`).
    static func shoulderWidth(for line: String?) -> CGFloat {
        let (first, second) = halves(of: line)
        let font = NSFont(name: Typography.postScriptName, size: Typography.captionSize)
            ?? .monospacedSystemFont(ofSize: Typography.captionSize, weight: .regular)
        func width(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        let content = ceil(max(width(first), width(second)))
        let needed = content + Theme.Metrics.collapsedHorizontalPadding + Theme.Metrics.shoulderInset + 2
        return min(
            max(needed, Theme.Metrics.LiveActivity.lyricsMinimumShoulderWidth),
            Theme.Metrics.LiveActivity.lyricsShoulderWidth
        )
    }
}
