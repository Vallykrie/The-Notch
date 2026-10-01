import AppKit
import Combine
import CoreAudio
import CoreGraphics
import Foundation

/// Consumes supported media keys before Control Center handles them. The notch is
/// updated only after a successful write; unsupported devices retain native controls.
@MainActor
final class MediaKeyInterceptor: ObservableObject {
    enum Status: String {
        case stopped = "Off"
        case active = "Keyboard connected"
        case permissionRequired = "Enable Accessibility"
        /// An earlier build held the grant and this one does not — see `AccessibilityGrant`.
        case permissionLost = "Re-add to Accessibility"
        case unavailable = "Check Accessibility"
    }
    @Published private(set) var status: Status = .stopped
    var onHandledEvent: ((SystemHUDEvent) -> Void)?
    private var keyRoutes: [Int32: Bool] = [:]
    private let grant = AccessibilityGrant()

    func openPermissionSettings() {
        requestPermissionIfNeeded()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The `NSSystemDefined` subtype that carries keyboard media keys. Every other subtype on
    /// that event type is something else entirely (mouse buttons, power state) and is passed
    /// through untouched.
    private static let auxKeySubtype: Int16 = 8

    /// `NSEvent.EventType.systemDefined`, as a `CGEventType`. Core Graphics does not name this
    /// one — `CGEventType` stops at `.scrollWheel` and the rest of the AppKit event types are
    /// reachable only by raw value — so the number is spelled out here once rather than being
    /// re-derived at each of the three places that need it.
    private static let systemDefinedEventType: UInt32 = 14

    /// `NX_KEYTYPE_*` from `IOKit/hidsystem/ev_keymap.h`, which is not importable from Swift.
    /// Only the five that draw a HUD are listed: play/pause, next and previous are deliberately
    /// absent, because consuming those would break every music app on the machine and they draw
    /// no banner anyway.
    private enum AuxKey: Int32 {
        case soundUp = 0
        case soundDown = 1
        case brightnessUp = 2
        case brightnessDown = 3
        case mute = 7
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var trustPollTask: Task<Void, Never>?

    /// Whether the tap is enabled and can consume media-key events.
    private(set) var isIntercepting = false

    /// Starts intercepting, or starts waiting for permission to.
    ///
    /// Accessibility is granted asynchronously, in System Settings, possibly minutes after
    /// launch, and there is no notification for it. So an ungranted launch polls — slowly, and
    /// only until it succeeds. A `CGEvent.tapCreate` that returns `nil` is the authoritative
    /// answer here rather than `AXIsProcessTrusted()`: the trust database can say yes while the
    /// tap is still refused, and the tap is the thing we actually need.
    func start() {
        guard trustPollTask == nil else { return }
        _ = install()
        startWaitingForPermission()
    }

    func stop() {
        trustPollTask?.cancel()
        trustPollTask = nil
        isIntercepting = false
        status = .stopped
        keyRoutes.removeAll()

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        // The port has to be invalidated as well as removed. A `CFMachPort` left valid keeps its
        // callback registered with the run loop's port set, so the C trampoline below can still
        // be entered with a `userInfo` pointer to an object that is on its way out.
        if let tap {
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        tap = nil
    }

    isolated deinit {
        // Same reasoning as `SystemHUDMonitor`: the tap outlives its registrant, and a released
        // interceptor whose port is still valid is a callback into freed memory the next time
        // the user touches a volume key.
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        trustPollTask?.cancel()
    }

    // MARK: Installing

    /// Asks for the grant at most once per build, not once per launch.
    ///
    /// `AXIsProcessTrustedWithOptions` with the prompt option opens System Settings every time
    /// it is called while untrusted, so calling it on every launch means an app that hijacks the
    /// foreground each morning until the user relents. Once per *machine* was the old rule, and
    /// it was too few: an update that lost the grant never asked again, and the HUD replacement
    /// went dark with nothing but a grey settings label to say why. `AccessibilityGrant` decides.
    func requestPermissionIfNeeded() {
        let isTrusted = AXIsProcessTrusted()
        if isTrusted { grant.recordTrusted() }
        guard grant.shouldPrompt(isTrusted: isTrusted) else { return }
        grant.recordPrompted()

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// What to show while the tap is not running for want of the grant.
    private var untrustedStatus: Status {
        grant.isLost(isTrusted: false) ? .permissionLost : .permissionRequired
    }

    private func install() -> Bool {
        guard AXIsProcessTrusted() else {
            status = untrustedStatus
            return false
        }
        grant.recordTrusted()
        let mask = CGEventMask(1) << Self.systemDefinedEventType
        // `.headInsertEventTap` and not `.tailAppendEventTap`: the whole point is to be ahead of
        // whatever handles the key and requests the banner. `.defaultTap` rather than
        // `.listenOnly` because a listen-only tap cannot discard the event, which is the one
        // thing this has to do.
        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let interceptor = Unmanaged<MediaKeyInterceptor>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                // The tap is attached to the main run loop, so the callback is already on the
                // main thread; `assumeIsolated` records that rather than hopping, which a tap
                // callback cannot do — it has to return a verdict synchronously.
                return MainActor.assumeIsolated {
                    interceptor.handle(type: type, event: event)
                }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            status = .unavailable
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            return false
        }

        tap = port
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        isIntercepting = CGEvent.tapIsEnabled(tap: port)
        status = isIntercepting ? .active : .unavailable
        return true
    }

    private func startWaitingForPermission() {
        guard trustPollTask == nil else { return }
        trustPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Theme.Metrics.HUD.permissionPollInterval))
                guard let self, !Task.isCancelled else { return }
                if let tap {
                    let trusted = AXIsProcessTrusted()
                    if trusted {
                        grant.recordTrusted()
                        if !CGEvent.tapIsEnabled(tap: tap) {
                            CGEvent.tapEnable(tap: tap, enable: true)
                        }
                    }
                    isIntercepting = trusted && CGEvent.tapIsEnabled(tap: tap)
                    let next: Status = isIntercepting ? .active : (trusted ? .unavailable : untrustedStatus)
                    if status != next { status = next }
                } else {
                    _ = install()
                }
            }
        }
    }

    // MARK: Handling

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // A tap that takes too long in its callback, or that is open when a login window
        // appears, is disabled by the system rather than removed. Without this the feature dies
        // silently mid-session and the native HUD comes back with no explanation.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                isIntercepting = CGEvent.tapIsEnabled(tap: tap)
                status = isIntercepting ? .active : .unavailable
                keyRoutes.removeAll()
            }
            return Unmanaged.passUnretained(event)
        }

        guard type.rawValue == Self.systemDefinedEventType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == Self.auxKeySubtype,
              let key = AuxKey(rawValue: Int32((nsEvent.data1 & 0xFFFF_0000) >> 16))
        else {
            return Unmanaged.passUnretained(event)
        }

        // `data1`'s low half is the key state: bits 8–15 hold 0xA for a press and 0xB for a
        // release, and bit 0 marks an auto-repeat while the key is held. Releases are consumed
        // without acting — passing one through after having swallowed its press leaves the
        // system with an unbalanced key state.
        let isDown = (nsEvent.data1 & 0xFF00) >> 8 == 0x0A
        guard isDown else {
            return keyRoutes.removeValue(forKey: key.rawValue) == true ? nil : Unmanaged.passUnretained(event)
        }
        if keyRoutes[key.rawValue] == false { return Unmanaged.passUnretained(event) }
        // Option alone opens the corresponding macOS settings pane.
        if nsEvent.modifierFlags.contains(.option), !nsEvent.modifierFlags.contains(.shift) {
            keyRoutes[key.rawValue] = false
            return Unmanaged.passUnretained(event)
        }

        // Shift+Option is macOS's own quarter-step modifier on these keys, and users who know
        // it will try it here. Matching it is the difference between replacing the system
        // behaviour and merely approximating it.
        let isFineStep = nsEvent.modifierFlags
            .intersection([.shift, .option]) == [.shift, .option]
        let step = isFineStep
            ? Theme.Metrics.HUD.fineKeyStep
            : Theme.Metrics.HUD.keyStep

        let didHandle: Bool
        switch key {
        case .soundUp: didHandle = applyVolume(delta: step)
        case .soundDown: didHandle = applyVolume(delta: -step)
        case .mute: didHandle = toggleMute()
        case .brightnessUp: didHandle = applyBrightness(delta: step)
        case .brightnessDown: didHandle = applyBrightness(delta: -step)
        }

        // Only swallow what we actually applied. A machine with no software volume control, or
        // an OS that has moved `DisplayServicesSetBrightness`, must fall back to macOS handling
        // the key — a dead brightness key is a far worse defect than a duplicated HUD.
        keyRoutes[key.rawValue] = didHandle
        return didHandle ? nil : Unmanaged.passUnretained(event)
    }

    // MARK: Applying

    private func applyVolume(delta: Float) -> Bool {
        guard let device = SystemHUDMonitor.defaultOutputDevice() else { return false }

        var address = SystemHUDMonitor.volumeAddress
        guard Self.isSettable(address, on: device),
              let current = SystemHUDMonitor.volume(of: device)
        else {
            return false
        }

        // Snapping to the step grid, not just adding to the current level. A level set from a
        // Control Centre slider lands anywhere, and adding 1/16 to 0.413 would keep every
        // subsequent press off-grid forever — so the first press after a drag rounds onto the
        // grid and every one after it moves a clean step.
        let stepped = ((current / abs(delta)).rounded() + (delta > 0 ? 1 : -1)) * abs(delta)
        var level = min(max(stepped, 0), 1)
        let status = AudioObjectSetPropertyData(
            device,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float>.size),
            &level
        )
        guard status == noErr else { return false }

        // Raising the volume off zero has to clear mute as well, or the level moves and nothing
        // is audible — which is what macOS itself does.
        if level > 0, delta > 0 {
            _ = setMute(false, on: device)
        }
        onHandledEvent?(.volume(level: Double(level), isMuted: SystemHUDMonitor.isMuted(device) ?? false))
        return true
    }

    private func toggleMute() -> Bool {
        guard let device = SystemHUDMonitor.defaultOutputDevice(),
              let isMuted = SystemHUDMonitor.isMuted(device)
        else {
            return false
        }
        guard setMute(!isMuted, on: device) else { return false }
        onHandledEvent?(.volume(level: Double(SystemHUDMonitor.volume(of: device) ?? 0), isMuted: !isMuted))
        return true
    }

    @discardableResult
    private func setMute(_ isMuted: Bool, on device: AudioDeviceID) -> Bool {
        var address = SystemHUDMonitor.muteAddress
        guard Self.isSettable(address, on: device) else { return false }

        var value: UInt32 = isMuted ? 1 : 0
        return AudioObjectSetPropertyData(
            device,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &value
        ) == noErr
    }

    /// Present *and* writable. Aggregate and virtual devices routinely expose a volume property
    /// that is read-only, and writing one fails silently — which would consume the key press and
    /// leave the level where it was, the one outcome worse than a duplicated HUD.
    private static func isSettable(
        _ address: AudioObjectPropertyAddress,
        on device: AudioDeviceID
    ) -> Bool {
        var address = address
        guard AudioObjectHasProperty(device, &address) else { return false }

        var isSettable = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(device, &address, &isSettable)
        return status == noErr && isSettable.boolValue
    }

    private func applyBrightness(delta: Float) -> Bool {
        guard let getBrightness = DisplayServicesBridge.getBrightness,
              let setBrightness = DisplayServicesBridge.setBrightness
        else {
            return false
        }

        // The built-in display may not be the main display when an external monitor
        // owns the menu bar. Brightness keys still need to reach the laptop panel.
        let display = Self.brightnessDisplay()
        var current = Float(0)
        guard getBrightness(display, &current) == 0, current.isFinite else { return false }

        let stepped = ((current / abs(delta)).rounded() + (delta > 0 ? 1 : -1)) * abs(delta)
        let level = min(max(stepped, 0), 1)
        guard setBrightness(display, level) == 0 else { return false }
        onHandledEvent?(.brightness(level: Double(level)))
        return true
    }

    static func brightnessDisplay() -> CGDirectDisplayID {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &displays, &count) == .success else { return CGMainDisplayID() }
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
    }
}
