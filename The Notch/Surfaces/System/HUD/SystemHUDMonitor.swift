import AudioToolbox
import Combine
import CoreAudio
import CoreGraphics
import Foundation

/// Presents only key presses that the interceptor actually consumed. Observing global
/// level changes also observes keys handled by Control Center, causing duplicate HUDs.
@MainActor
final class SystemHUDMonitor: ObservableObject {
    @Published private(set) var event: SystemHUDEvent?
    private var isRunning = false
    private var dwellTask: Task<Void, Never>?
    var dwell: TimeInterval = Theme.Metrics.HUD.dwell

    static func preview(_ event: SystemHUDEvent) -> SystemHUDMonitor {
        let monitor = SystemHUDMonitor()
        monitor.event = event
        return monitor
    }

    static func previewIdle() -> SystemHUDMonitor { SystemHUDMonitor() }

    func start() { isRunning = true }

    func stop() {
        isRunning = false
        dwellTask?.cancel()
        dwellTask = nil
        event = nil
    }

    func presentIntercepted(_ newEvent: SystemHUDEvent) {
        guard isRunning else { return }
        event = newEvent
        dwellTask?.cancel()
        let dwell = dwell
        dwellTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(dwell))
            guard !Task.isCancelled else { return }
            self?.event = nil
            self?.dwellTask = nil
        }
    }

    isolated deinit { dwellTask?.cancel() }

    private static var defaultOutputDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// The *virtual* main volume, not `kAudioDevicePropertyVolumeScalar`. The latter is
    /// per-channel and absent on devices that expose only a master control, so reading it means
    /// enumerating channels and picking one — and the number the user is adjusting with the
    /// volume key is this one anyway.
    static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func defaultOutputDevice() -> AudioDeviceID? {
        var address = defaultOutputDeviceAddress
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        )
        guard status == noErr, device != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return device
    }

    static func volume(of device: AudioDeviceID) -> Float? {
        var address = volumeAddress
        guard AudioObjectHasProperty(device, &address) else { return nil }

        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr, value.isFinite else { return nil }
        return value
    }

    static func isMuted(_ device: AudioDeviceID) -> Bool? {
        var address = muteAddress
        guard AudioObjectHasProperty(device, &address) else { return nil }

        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value != 0
    }

}

/// The two private symbols this app resolves at runtime.
///
/// `dlopen`'d rather than linked: linking a private framework makes the whole binary fail to
/// launch the day Apple moves or removes it, whereas a failed `dlsym` costs exactly one absent
/// feature. The handle is deliberately never `dlclose`'d — the function pointer below outlives
/// any scope we could close it in, and closing the image invalidates it.
enum DisplayServicesBridge {
    typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>)
        -> Int32
    typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    /// Resolved once, lazily, on first use. `@convention(c)` function types are `Sendable`, so
    /// this needs no isolation annotation — it is a constant address into an image that is never
    /// unloaded, and there is nothing to race on.
    static let getBrightness: GetBrightness? = symbol("DisplayServicesGetBrightness")

    /// Used only by `MediaKeyInterceptor`, which has to apply the level itself once it has taken
    /// the brightness key away from macOS.
    ///
    /// `DisplayServicesSetBrightness` and **not** `DisplayServicesSetBrightnessSmooth`, which
    /// looks like the better choice and is a trap: the smooth variant exports from this
    /// framework on macOS 26, accepts `(display, level)`, and returns `0` — while leaving the
    /// backlight exactly where it was. It was measured doing nothing before it was swapped out.
    /// Whatever its real signature is, it is not this one, and a setter that reports success
    /// without setting anything would make the brightness key silently dead.
    ///
    /// A machine where even this symbol is missing simply hands the key back to macOS — see
    /// `MediaKeyInterceptor.applyBrightness`.
    static let setBrightness: SetBrightness? = symbol("DisplayServicesSetBrightness")

    private static func symbol<Function>(_ name: String) -> Function? {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY) else { return nil }
        guard let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }
}
