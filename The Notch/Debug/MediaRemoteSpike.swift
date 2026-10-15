#if DEBUG
import AppKit
import Foundation

/// Phase 0 spike for browser media (docs/design/browser-media-plan.md). It proves that the
/// bundled MediaRemoteAdapter works when *this app* launches it: runs `test`, then streams
/// now-playing updates and prints one summary line per update.
///
/// Activated only by `NOTCH_MR_SPIKE=<seconds>`; the app exits when the stream window ends.
/// Throwaway: Phase 1 replaces it with a real `MediaSource`.
@MainActor
enum MediaRemoteSpike {
    static var requestedDuration: TimeInterval? {
        ProcessInfo.processInfo.environment["NOTCH_MR_SPIKE"].flatMap(TimeInterval.init)
    }

    static func run(seconds: TimeInterval) {
        let contents = Bundle.main.bundleURL.appending(path: "Contents")
        let script = contents.appending(path: "Resources/mediaremote-adapter.pl").path
        let framework = contents.appending(path: "Frameworks/MediaRemoteAdapter.framework").path
        let testClient = contents.appending(path: "Helpers/MediaRemoteAdapterTestClient").path

        let clock = ContinuousClock()
        let started = clock.now
        let test = perl([script, framework, testClient, "test"])
        test.waitUntilExit()
        log("test exit=\(test.terminationStatus) in \(clock.now - started)")
        guard test.terminationStatus == 0 else { return }

        let stream = perl([script, framework, "stream", "--debounce=100"])
        let pipe = stream.standardOutput as! Pipe
        var buffer = Data()
        var snapshot: [String: Any] = [:]
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            DispatchQueue.main.async {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    apply(line: Data(line), to: &snapshot)
                }
            }
        }

        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        stream.terminate()
        stream.waitUntilExit()
        log("stream exit=\(stream.terminationStatus)")
    }

    private static func perl(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/perl")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = FileHandle.standardError
        try? process.run()
        return process
    }

    private static func apply(line: Data, to snapshot: inout [String: Any]) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            log("unparsable line (\(line.count) bytes)")
            return
        }
        let payload = object["payload"] as? [String: Any] ?? [:]
        if object["diff"] as? Bool == true {
            for (key, value) in payload {
                if value is NSNull { snapshot.removeValue(forKey: key) } else { snapshot[key] = value }
            }
        } else {
            snapshot = payload
        }

        let artwork = (snapshot["artworkData"] as? String).map { "\($0.count / 1_024) KB b64" } ?? "none"
        let fields = [
            "bundle=\(snapshot["bundleIdentifier"] ?? "-")",
            "playing=\(snapshot["playing"] ?? "-")",
            "title=\(snapshot["title"] ?? "-")",
            "artist=\(snapshot["artist"] ?? "-")",
            "elapsed=\(snapshot["elapsedTime"] ?? "-")/\(snapshot["duration"] ?? "-")",
            "rate=\(snapshot["playbackRate"] ?? "-")",
            "type=\(snapshot["mediaType"] ?? "-")",
            "artwork=\(artwork)",
            "changed=\(payload.keys.sorted().joined(separator: ","))",
        ]
        log(fields.joined(separator: " | "))
    }

    private static func log(_ message: String) {
        print("[mr-spike] \(message)")
        fflush(stdout)
    }
}
#endif
