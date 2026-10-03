import Foundation

extension LiveActivityLayout {
    /// How wide one shoulder is. Both shoulders always take this value — see
    /// `NotchCoordinator.collapsedSize` for why the silhouette has to stay symmetric.
    ///
    /// Two widths, not one. The live activities are compact by design: their shoulders hold a
    /// single glyph-sized mark, so anything wider than the mark is dead black band. The HUD is
    /// the exception and is wider on purpose — a level bar has to be long enough to resolve a
    /// step of 1/16, and the width difference is itself the signal that the notch is answering
    /// a key press rather than reporting background activity.
    var shoulderWidth: CGFloat {
        switch self {
        case .idle, .mediaOnly, .agentsOnly, .both:
            Theme.Metrics.LiveActivity.compactShoulderWidth
        case .systemHUD:
            Theme.Metrics.LiveActivity.hudShoulderWidth
        case .trading:
            Theme.Metrics.Trading.shoulderWidth
        case let .lyrics(shoulderWidth):
            shoulderWidth
        }
    }

    /// A faux notch has no camera to reserve space for. Keep trading's two text
    /// shoulders close together while preserving the real hardware exclusion zone.
    func housingWidth(physicalWidth: CGFloat, hasPhysicalNotch: Bool) -> CGFloat {
        (self == .trading || isLyrics) && !hasPhysicalNotch ? Theme.Metrics.Trading.fauxHousingGap : physicalWidth
    }

    /// The outer padding a shoulder's content hugs. The compact cases cannot afford the
    /// text-sized `collapsedHorizontalPadding`: at 13 a side, the 18pt artwork does not fit
    /// inside a 40pt shoulder at all.
    var horizontalPadding: CGFloat {
        switch self {
        case .idle, .mediaOnly, .agentsOnly, .both:
            Theme.Metrics.LiveActivity.compactHorizontalPadding
        case .systemHUD, .trading, .lyrics:
            Theme.Metrics.collapsedHorizontalPadding
        }
    }
}
