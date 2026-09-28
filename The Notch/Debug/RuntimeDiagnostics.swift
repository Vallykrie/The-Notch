import AppKit
import CoreAudio

@MainActor
enum RuntimeDiagnostics {
    /// Runs in the app's own signed identity, so Accessibility checks reflect The Notch,
    /// not whichever terminal launched the diagnostic. No hook/config writes here.
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--diagnostics") else { return false }
        Task { @MainActor in
            let keys = MediaKeyInterceptor()
            keys.start()
            var intercepted = 0
            keys.onHandledEvent = { _ in intercepted += 1 }
            var result: [String: Any] = [
                "accessibility": AXIsProcessTrusted(),
                "mediaKeyTap": keys.isIntercepting,
                "brightnessAPI": DisplayServicesBridge.setBrightness != nil,
                "providers": AgentCLIDetector().detect().filter(\.isInstalled).map { $0.agent.rawValue },
            ]
            if keys.isIntercepting, CommandLine.arguments.contains("--test-media-keys") {
                let device = SystemHUDMonitor.defaultOutputDevice()
                let volume = device.flatMap { SystemHUDMonitor.volume(of: $0) }
                let muted = device.flatMap { SystemHUDMonitor.isMuted($0) }
                let display = MediaKeyInterceptor.brightnessDisplay()
                var brightness: Float = 0
                let hasBrightness = DisplayServicesBridge.getBrightness?(display, &brightness) == 0
                for key in [1, 0, 3, 2] {
                    for state in [0xA, 0xB] {
                        NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, subtype: 8, data1: (key << 16) | (state << 8), data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
                    }
                    try? await Task.sleep(for: .milliseconds(150))
                }
                if let device, var volume {
                    var address = SystemHUDMonitor.volumeAddress
                    _ = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &volume)
                }
                if let device, let muted {
                    var value: UInt32 = muted ? 1 : 0
                    var address = SystemHUDMonitor.muteAddress
                    _ = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
                }
                if hasBrightness { _ = DisplayServicesBridge.setBrightness?(display, brightness) }
                result["interceptedTestKeys"] = intercepted
                result["expectedTestKeys"] = 4
            }
            keys.stop()
            let reader = CodexSessionReader()
            result["activeCodexSessions"] = await reader.poll().count
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) { print(text) }
            NSApp.terminate(nil)
        }
        return true
    }
}
