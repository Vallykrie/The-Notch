import Foundation

/// One level readout the notch is currently standing in for: the macOS volume or brightness HUD.
///
/// Deliberately a value type with no identity and no timestamp. The monitor owns *when* an event
/// is live and when it clears; this only says *what* is being shown. An earlier sketch carried a
/// `Date` so the view could expire itself, which put the dwell rule in two places and made the
/// two disagree whenever the poll and the render landed in different run loop turns.
enum SystemHUDEvent: Equatable, Sendable {
    case volume(level: Double, isMuted: Bool)
    case brightness(level: Double)

    /// 0...1. Clamped here rather than at every producer: CoreAudio's virtual main volume is
    /// documented as 0...1 but a device with an unusual volume curve can report a hair over 1,
    /// and `DisplayServicesGetBrightness` returns whatever the panel's driver last wrote. A bar
    /// wider than its own track is the visible failure, so the clamp lives at the boundary the
    /// view reads from.
    var level: Double {
        switch self {
        case let .volume(level, _):
            Self.clamped(level)
        case let .brightness(level):
            Self.clamped(level)
        }
    }

    /// The word beside the sprite. Not localised, for the same reason nothing else in the shell
    /// is yet — there is no string catalogue in the project, and adding one for two words would
    /// be the only localised surface in the app.
    var label: String {
        switch self {
        case .volume(_, true):
            "Muted"
        case .volume(_, false):
            "Volume"
        case .brightness:
            "Brightness"
        }
    }

    /// The muted speaker complements the HUD's amber tint and explicit label.
    var glyph: PixelGlyph {
        switch self {
        case let .volume(_, isMuted):
            isMuted ? .speakerMuted : .speaker
        case .brightness:
            .brightness
        }
    }

    private static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
