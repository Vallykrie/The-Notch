import Darwin
import Foundation

/// What can be read about another process of the same user without spawning `ps`.
nonisolated enum ProcessInspector {
    struct CommandLine: Sendable {
        var arguments: [String]
        var environment: [String: String]
    }

    /// `argv` and the environment via `KERN_PROCARGS2`: an `argc`, the exec path, padding,
    /// `argc` argument strings, then `KEY=value` strings until an empty one. Fails for other
    /// users' processes, which is fine — an agent the user runs is theirs.
    ///
    /// `environmentKeys` limits what is kept, so a scan of every process does not build a
    /// dictionary of every variable of every one of them.
    static func commandLine(of pid: pid_t, environmentKeys: Set<String> = []) -> CommandLine? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // Skip the exec path and the NUL padding after it.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        func nextString() -> String? {
            guard index < size else { return nil }
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            defer { index += 1 }
            return String(decoding: buffer[start..<index], as: UTF8.self)
        }

        var result = CommandLine(arguments: [], environment: [:])
        while result.arguments.count < Int(argc), let argument = nextString() {
            result.arguments.append(argument)
        }
        guard !environmentKeys.isEmpty else { return result }
        while let entry = nextString(), !entry.isEmpty {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<equals])
            if environmentKeys.contains(key) {
                result.environment[key] = String(entry[entry.index(after: equals)...])
            }
        }
        return result
    }

    /// The controlling terminal, as `/dev/ttys003`, or `nil` for a process without one.
    static func ttyPath(of pid: pid_t) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let device = info.kp_eproc.e_tdev
        guard device != -1, let name = devname(device, S_IFCHR) else { return nil }
        let string = String(cString: name)
        return string.isEmpty || string == "??" ? nil : "/dev/" + string
    }

    static func basename(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
