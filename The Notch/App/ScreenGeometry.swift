import AppKit
import CoreGraphics

@MainActor
struct ScreenGeometry {
    let screen: NSScreen
    let collapsedNotchSize: CGSize
    let panelFrame: CGRect
    let hasPhysicalNotch: Bool

    static func preferredScreen(
        from screens: [NSScreen] = NSScreen.screens,
        mainScreen: NSScreen? = NSScreen.main
    ) -> NSScreen? {
        if let builtIn = screens.first(where: { screen in
            guard let displayID = screen.displayID else { return false }
            return CGDisplayIsBuiltin(displayID) != 0
        }) {
            return builtIn
        }

        if let mainScreen, screens.contains(where: { $0 === mainScreen }) {
            return mainScreen
        }

        return screens.first
    }

    static func resolve(for screen: NSScreen) -> ScreenGeometry {
        let safeTop = screen.safeAreaInsets.top
        let leftArea = screen.auxiliaryTopLeftArea
        let rightArea = screen.auxiliaryTopRightArea
        let hasPhysicalNotch = safeTop > .zero && leftArea != nil && rightArea != nil

        let collapsedSize: CGSize
        if hasPhysicalNotch, let leftArea, let rightArea {
            let measuredWidth = screen.frame.width - leftArea.width - rightArea.width
            collapsedSize = CGSize(
                width: measuredWidth > .zero
                    ? measuredWidth + Theme.Metrics.bezelOverlap * 2
                    : Theme.Metrics.fauxNotchSize.width,
                height: safeTop
            )
        } else {
            collapsedSize = Theme.Metrics.fauxNotchSize
        }

        // The panel is deliberately larger than the widest silhouette: the drop shadow and the
        // expanded hover grace zone both live outside the notch shape, and anything outside the
        // panel is clipped. The pointer monitor keeps the window itself out of the window
        // server's hit list across this margin, so clicks genuinely reach whatever is behind.
        // The widest *collapsed* silhouette is the HUD's, not a live activity's: shoulders are
        // sized per layout now and the HUD's are more than twice a compact one. Sizing the
        // panel from anything narrower clips the drop shadow off the ends of the HUD.
        // The first-launch band is the widest and tallest thing the notch ever becomes, and the
        // confetti and the lyric pill fall below whatever is open, inside the bottom margin.
        let widestSilhouette = max(
            collapsedSize.width + Theme.Metrics.LiveActivity.hudShoulderWidth * 2,
            Theme.Metrics.expandedNotchSize.width,
            Theme.Metrics.onboardingBandSize.width
        )
        let tallestSilhouette = max(
            collapsedSize.height,
            Theme.Metrics.expandedNotchSize.height,
            Theme.Metrics.onboardingBandSize.height
        )
        let panelSize = CGSize(
            width: min(
                screen.frame.width,
                widestSilhouette + Theme.Metrics.panelHorizontalMargin * 2
            ),
            height: tallestSilhouette + Theme.Metrics.panelBottomMargin
        )
        let panelFrame = CGRect(
            x: screen.frame.midX - panelSize.width / 2,
            y: screen.frame.maxY - panelSize.height,
            width: panelSize.width,
            height: panelSize.height
        )

        return ScreenGeometry(
            screen: screen,
            collapsedNotchSize: collapsedSize,
            panelFrame: panelFrame,
            hasPhysicalNotch: hasPhysicalNotch
        )
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }
}
