import AppKit
import SwiftUI

@MainActor
final class NotchWindow: NSPanel {
    private let notchHostingView: NotchHostingView

    init(
        geometry: ScreenGeometry,
        coordinator: NotchCoordinator,
        store: AgentSessionStore,
        services: SystemServices
    ) {
        coordinator.updateGeometry(
            collapsedSize: geometry.collapsedNotchSize,
            hasPhysicalNotch: geometry.hasPhysicalNotch
        )
        notchHostingView = NotchHostingView(
            rootView: NotchRootView(coordinator: coordinator, store: store, services: services),
            coordinator: coordinator,
            settings: services.settings
        )

        // Must be the *designated* initializer. The `screen:` variant is a convenience that
        // funnels through this one, which traps at runtime unless the subclass implements it.
        // `panelFrame` is already in global screen coordinates, so `screen:` bought us nothing.
        super.init(
            contentRect: geometry.panelFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // The panel is much larger than the drawn notch so its shadow is not clipped. Start
        // outside the window server's mouse hit list; the hosting view opts the live region
        // back in once both pointer monitors are installed and the cursor can be located.
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        level = .statusBar
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]

        contentView = notchHostingView
        notchHostingView.frame = NSRect(origin: .zero, size: geometry.panelFrame.size)
        notchHostingView.autoresizingMask = [.width, .height]
        notchHostingView.startMonitoringPointer()

        // Deferred to the next runloop turn on purpose. `setState` is called from inside
        // `withAnimation`, and this callback drives `needsLayout` and re-evaluates the live
        // pointer region on the AppKit host. Running that synchronously forces a layout pass
        // while SwiftUI's transaction is still open, which commits the new size immediately
        // and discards the spring — the notch jumped straight to full size no matter how long
        // the animation was.
        // The pointer region only has to be correct by the time the cursor can move again.
        coordinator.stateDidChange = { [weak notchHostingView] _ in
            DispatchQueue.main.async {
                notchHostingView?.coordinatorStateDidChange()
            }
        }

        // TODO: Replace this panel behind the seam below with SkyLightWindow when that
        // dependency is available; private window ordering is required above fullscreen apps.
        configureFullscreenPresentationSeam()
    }

    /// The approval card offers `return` to allow and `escape` to deny, and a panel that can
    /// never become key receives no key events at all — the shortcuts would be decorative.
    ///
    /// Deliberately *not* paired with an automatic `makeKey()` when an approval arrives: an
    /// agent can block at any moment, and silently stealing keystrokes from whatever the user
    /// is typing into would be worse than having no shortcut. Clicking the notch makes it key;
    /// until then it stays out of the way. `canBecomeMain` remains false so the app never
    /// activates over the user's frontmost window.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func apply(_ geometry: ScreenGeometry, coordinator: NotchCoordinator) {
        coordinator.updateGeometry(
            collapsedSize: geometry.collapsedNotchSize,
            hasPhysicalNotch: geometry.hasPhysicalNotch
        )
        setFrame(geometry.panelFrame, display: true, animate: false)
        notchHostingView.frame = NSRect(origin: .zero, size: geometry.panelFrame.size)
        notchHostingView.coordinatorStateDidChange()
    }

    private func configureFullscreenPresentationSeam() {
        // Intentionally empty until a SkyLightWindow-backed implementation can be supplied.
    }
}

@MainActor
private final class NotchHostingView: NSHostingView<NotchRootView> {
    private let coordinator: NotchCoordinator
    /// Read for the hover preferences only. Not observed: the values are consulted at the moment
    /// a transition is scheduled, so a change takes effect on the very next hover without this
    /// view needing to hear about it.
    private let settings: NotchSettings
    private var hoverTask: Task<Void, Never>?
    /// The last pin state this view acted on. Releasing the pin has to schedule the collapse
    /// that the pin suppressed, and by then the pointer has usually been outside for a while —
    /// so `pointerIsInsideLiveRegion` has not changed and would swallow the transition.
    private var wasPinnedOpen = false
    private var globalPointerMonitor: Any?
    private var localPointerMonitor: Any?
    private var pointerIsInsideLiveRegion: Bool?

    private static let pointerEventMask: NSEvent.EventTypeMask = [
        .mouseMoved,
        .leftMouseDragged,
        .rightMouseDragged,
    ]

    init(rootView: NotchRootView, coordinator: NotchCoordinator, settings: NotchSettings) {
        self.coordinator = coordinator
        self.settings = settings
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init(rootView: NotchRootView) {
        fatalError("Use init(rootView:coordinator:)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        hoverTask?.cancel()
        if let globalPointerMonitor {
            NSEvent.removeMonitor(globalPointerMonitor)
        }
        if let localPointerMonitor {
            NSEvent.removeMonitor(localPointerMonitor)
        }
    }

    /// `point` arrives in the *superview's* coordinate space, which is not flipped, while
    /// `notchPath` is built in this view's flipped space. Comparing them directly mirrored the
    /// hit region to the bottom of the panel: the notch itself was click-through and never
    /// received hover samples, so expansion could not fire at all.
    ///
    /// Returning `nil` here remains a cheap second line of defence, but it cannot make the
    /// panel genuinely click-through. AppKit has already chosen a window before asking that
    /// window for a view; declining the view hit only discards the event instead of forwarding
    /// it to the menu bar or window behind. The pointer monitor drives `ignoresMouseEvents` to
    /// remove the panel itself from the window server's hit list outside this same region.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        guard hitRegion.contains(local) else { return nil }
        return super.hitTest(point) ?? self
    }

    /// Collapsed, only the part of the silhouette that can actually hold content is live, so the
    /// menu bar stays usable. Expanded, the grace ring counts as inside — otherwise the panel
    /// would collapse the instant the pointer grazed the rounded corner on its way to a button.
    private var hitRegion: CGPath {
        guard coordinator.state == .expanded else { return collapsedHitRegion }
        return CGPath(rect: trackingRect, transform: nil)
    }

    /// Once the resting silhouette grew shoulders it became ~350pt of `.statusBar`-level panel
    /// lying across the menu bar, and the outer reaches of those shoulders draw nothing on a
    /// notched Mac — so the user saw bare menu bar, clicked it, and the click vanished into a
    /// panel that then did not even expand.
    ///
    /// Only the band either side of the housing is live. The housing column between the bands
    /// stays live deliberately: no menu bar content can sit behind the camera, and the pointer
    /// arriving from below crosses it, which is where hover expansion has to fire.
    private var collapsedHitRegion: CGPath {
        // Without a physical notch the faux pill has no dead middle — content spans the whole
        // silhouette, so all of it is real UI.
        guard coordinator.hasPhysicalNotch else { return notchPath }

        let silhouette = notchRect
        let live = CGRect(
            x: silhouette.midX - coordinator.physicalNotchSize.width / 2 - interactiveShoulderWidth,
            y: silhouette.minY,
            width: coordinator.physicalNotchSize.width + interactiveShoulderWidth * 2,
            height: silhouette.height
        )
        return CGPath(rect: live.intersection(silhouette), transform: nil)
    }

    /// How far out along a shoulder collapsed content can reach — which is now simply the
    /// whole shoulder.
    ///
    /// This used to compute the widest thing any surface could put on a shoulder (a three-
    /// sprite agent row) and clamp the live region to that, because the shoulders were 128pt
    /// each and their outer reaches drew nothing at all: the user saw bare menu bar, clicked
    /// it, and the click vanished into a panel that then did not even expand.
    ///
    /// Shoulders are now sized per layout and every active case fills its shoulder — artwork, a
    /// waveform, a level bar, a count. There is no dead outer band left to exclude, and
    /// excluding one anyway would make the far end of visible content unclickable.
    ///
    /// Read from the *live* layout rather than from the widest one. The compact live-activity
    /// shoulder is 40pt against the HUD's 92, so a fixed maximum here would claim 104pt of
    /// menu bar that the collapsed notch is not drawing on — which is the click-swallowing
    /// defect this property was introduced to fix, reintroduced from the other direction.
    private var interactiveShoulderWidth: CGFloat {
        coordinator.liveActivityLayout.shoulderWidth
    }

    func coordinatorStateDidChange() {
        needsLayout = true
        evaluatePointerPosition()
    }

    /// A tracking area cannot observe the pointer while its window ignores mouse events, so it
    /// cannot be used to decide when that same window should stop ignoring them. The global
    /// monitor sees movement over every other app; once the pointer reaches this panel, AppKit
    /// stops delivering those samples and the matching local monitor takes over. Mouse-move
    /// monitors are delivered on the main thread and require no Accessibility permission.
    func startMonitoringPointer() {
        guard globalPointerMonitor == nil, localPointerMonitor == nil else {
            evaluatePointerPosition()
            return
        }

        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: Self.pointerEventMask
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.evaluatePointerPosition()
            }
        }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(
            matching: Self.pointerEventMask
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.evaluatePointerPosition()
            }
            return event
        }

        // A half-installed pair leaves a blind spot exactly where the other monitor was meant
        // to take over. Fail closed to interaction — which is open to the desktop behind — and
        // remove the surviving token rather than letting the panel become unpredictably sticky.
        guard globalPointerMonitor != nil, localPointerMonitor != nil else {
            stopMonitoringPointer()
            window?.ignoresMouseEvents = true
            pointerIsInsideLiveRegion = nil
            return
        }

        evaluatePointerPosition()
    }

    private func stopMonitoringPointer() {
        if let globalPointerMonitor {
            NSEvent.removeMonitor(globalPointerMonitor)
            self.globalPointerMonitor = nil
        }
        if let localPointerMonitor {
            NSEvent.removeMonitor(localPointerMonitor)
            self.localPointerMonitor = nil
        }
    }

    private func evaluatePointerPosition() {
        guard globalPointerMonitor != nil, localPointerMonitor != nil else {
            window?.ignoresMouseEvents = true
            pointerIsInsideLiveRegion = nil
            return
        }
        guard let window else {
            pointerIsInsideLiveRegion = nil
            return
        }

        // Never change the window's participation in hit testing mid-drag. Once a button is
        // down AppKit has already routed the event stream to whichever window took the
        // `mouseDown`; flipping `ignoresMouseEvents` underneath that tears the stream in half.
        // Dragging a hair outside the silhouette on the way to a button would otherwise cancel
        // the click, and dragging *into* the notch from outside would hand it a stream whose
        // `mouseDown` it never saw. The next plain move re-evaluates, so this only defers.
        guard NSEvent.pressedMouseButtons == 0 else { return }

        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let pointInView = convert(pointInWindow, from: nil)
        let isInsideLiveRegion = hitRegion.contains(pointInView)
        window.ignoresMouseEvents = !isInsideLiveRegion

        // A pin release is a transition trigger in its own right. Settings closing while the
        // pointer sits somewhere else entirely leaves `pointerIsInsideLiveRegion` unchanged at
        // `false`, and the guard below would drop the collapse the release is supposed to cause.
        let pinDidChange = wasPinnedOpen != coordinator.isPinnedOpen
        wasPinnedOpen = coordinator.isPinnedOpen

        guard pointerIsInsideLiveRegion != isInsideLiveRegion || pinDidChange else { return }
        pointerIsInsideLiveRegion = isInsideLiveRegion

        let sensitivity = settings.hoverSensitivity
        scheduleTransition(
            to: isInsideLiveRegion ? .expanded : .collapsed,
            after: isInsideLiveRegion
                ? Theme.Motion.hoverEnterDelay(sensitivity)
                : Theme.Motion.hoverExitDelay(sensitivity)
        )
    }

    /// The silhouette in this view's own coordinate space. SwiftUI pins its content to the top
    /// of the panel regardless of flippedness, so this must follow the top edge, not `minY`.
    private var notchRect: CGRect {
        let size = coordinator.notchSize
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: isFlipped ? bounds.minY : bounds.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    private var notchPath: CGPath {
        NotchShape.cgPath(
            in: notchRect,
            topCornerRadius: coordinator.topCornerRadius,
            bottomCornerRadius: coordinator.bottomCornerRadius
        )
    }

    private var trackingRect: CGRect {
        guard coordinator.state == .expanded else { return notchRect }
        return notchRect.insetBy(
            dx: -Theme.Metrics.expandedTrackingInset,
            dy: -Theme.Metrics.expandedTrackingInset
        )
    }

    /// Opens the notch when hover expansion is switched off.
    ///
    /// Without this, `expandOnHover = false` would be `expandNever`: the collapsed silhouette is
    /// the only thing on screen and there is no other affordance to reach the panel through —
    /// no Dock icon, no menu bar item. A click on the collapsed notch does nothing else, so
    /// claiming it costs nothing. Expanded, the event falls straight through to SwiftUI, which
    /// owns every control in the panel.
    override func mouseDown(with event: NSEvent) {
        if coordinator.state == .collapsed {
            NotchRootView.transition(coordinator, to: .expanded)
        }
        super.mouseDown(with: event)
    }

    private func scheduleTransition(to state: NotchState, after delay: Duration) {
        // Cancelled before the refusals below, not after. A refused *expand* still has to kill
        // the pending collapse that the pointer's departure armed — otherwise, under
        // click-to-open, returning to a panel the user opened deliberately would let a collapse
        // scheduled 200ms ago fire underneath them.
        hoverTask?.cancel()

        // Never expand on hover alone when the user has asked for click-to-open. The *collapse*
        // side still runs on hover: leaving is how a click-opened panel closes, and requiring a
        // second click to dismiss a panel that lives in the menu bar would strand it open.
        if state == .expanded, !settings.expandOnHover { return }
        // The settings surface holds the panel open regardless of where the pointer is.
        if state == .collapsed, coordinator.isPinnedOpen { return }

        hoverTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }

            guard let self, !Task.isCancelled else { return }
            NotchRootView.transition(coordinator, to: state)
        }
    }
}
