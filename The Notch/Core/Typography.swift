import CoreText
import SwiftUI

/// The Notch speaks in one voice: a pixel-grid monospace, at a small set of sizes.
///
/// Departure Mono is drawn on a pixel grid, so it only looks correct at integer point sizes —
/// fractional sizes smear it into grey mush. Every size below is an integer, and surfaces must
/// pick from this scale rather than calling `.font(.system(...))`, which is what made the old
/// panel read as a stock SwiftUI sheet.
@MainActor
enum Typography {
    /// PostScript name, not the file name. `NSFont(name:)` will silently return nil for the
    /// family name ("Departure Mono"), which is how a missing font degrades into system San
    /// Francisco without anything logging.
    static let postScriptName = "DepartureMono-Regular"

    private static var didRegister = false

    /// Registers the bundled OTF with Core Text. The font ships inside the app bundle rather
    /// than being installed system-wide, so it has to be registered before first use — call
    /// this once, early, before any view builds.
    static func registerBundledFonts() {
        guard !didRegister else { return }
        didRegister = true

        guard
            let url = Bundle.main.url(
                forResource: "DepartureMono-Regular",
                withExtension: "otf"
            )
        else {
            assertionFailure("DepartureMono-Regular.otf is missing from the app bundle")
            return
        }

        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            // A duplicate registration is benign — a debug build relaunching over itself hits
            // this. Anything else means the type scale is silently falling back to system font.
            let code = error.map { CFErrorGetCode($0.takeUnretainedValue()) }
            if code != CTFontManagerError.alreadyRegistered.rawValue {
                assertionFailure("Failed to register Departure Mono: \(String(describing: error))")
            }
        }
    }

    /// `Font.custom(_:size:)` with no relative-to argument opts out of Dynamic Type scaling,
    /// which is what we want: the notch is a fixed-size piece of hardware trim, and letting the
    /// user's text-size preference reflow it would break the silhouette.
    private static func mono(_ size: CGFloat) -> Font {
        .custom(postScriptName, fixedSize: size)
    }

    /// 8pt — badge counts and unit suffixes riding next to a number.
    static let micro = mono(8)
    /// 9pt — the collapsed pill's shoulder text. Small enough to clear the camera housing.
    static let caption = mono(captionSize)
    /// The caption's size as a number, for measuring caption text with AppKit — the collapsed
    /// notch sizes its lyrics shoulders from the line's real width.
    static let captionSize: CGFloat = 9
    /// 11pt — the workhorse. Session rows, tool lines, secondary detail.
    static let body = mono(11)
    /// 13pt — row titles and the agent name on an approval card.
    static let title = mono(13)
    /// 16pt — the one line the panel wants you to read first.
    static let headline = mono(16)
    static let tradingPrice = mono(24)

    /// Departure Mono's advance width is exactly half its point size, which makes column
    /// alignment computable rather than guessed. Surfaces use this to reserve space for a
    /// known character count without measuring text.
    static func width(characters: Int, at size: CGFloat) -> CGFloat {
        CGFloat(characters) * size * 0.5
    }
}
