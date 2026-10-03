import Darwin
import Foundation

nonisolated struct ProcessAncestor: Equatable, Sendable {
    let processID: pid_t
    let parentProcessID: pid_t
    let executablePath: String?
    let bundleIdentifier: String?
}

nonisolated struct ProcessAncestry: Sendable {
    let processes: [ProcessAncestor]
    let owningApplicationBundleIdentifier: String?
}

/// Resolves terminal ownership without invoking `ps` or any other subprocess.
nonisolated struct ProcessAncestryStrategy: Sendable {
    private static let maximumDepth = 64

    func resolve(from target: JumpTarget) -> ProcessAncestry {
        guard let firstPID = target.processID ?? target.parentProcessID else {
            return ProcessAncestry(processes: [], owningApplicationBundleIdentifier: nil)
        }
        return resolve(fromProcessID: firstPID)
    }

    /// The same walk from a bare process, for when there is no session to build a target from —
    /// the empty agents panel finding which terminal a running CLI lives in.
    func resolve(fromProcessID firstPID: pid_t) -> ProcessAncestry {

        var ancestors: [ProcessAncestor] = []
        var seen: Set<pid_t> = []
        var currentPID = firstPID

        while currentPID > 1, ancestors.count < Self.maximumDepth, seen.insert(currentPID).inserted {
            guard let parentPID = parentProcessID(of: currentPID) else { break }
            let path = executablePath(of: currentPID)
            ancestors.append(
                ProcessAncestor(
                    processID: currentPID,
                    parentProcessID: parentPID,
                    executablePath: path,
                    bundleIdentifier: path.flatMap(bundleIdentifier(forExecutablePath:))
                )
            )
            currentPID = parentPID
        }

        let knownOwner = ancestors.lazy
            .compactMap(\.bundleIdentifier)
            .first(where: Self.isKnownTerminalOrIDE)
        let firstApplication = ancestors.lazy.compactMap(\.bundleIdentifier).first
        return ProcessAncestry(
            processes: ancestors,
            owningApplicationBundleIdentifier: knownOwner ?? firstApplication
        )
    }

    private func parentProcessID(of processID: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, pointer, Int32(size))
        }
        guard result == size, info.pbi_ppid > 0 else { return nil }
        return pid_t(info.pbi_ppid)
    }

    private func executablePath(of processID: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a non-importable C macro (4 * MAXPATHLEN).
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(processID, pointer.baseAddress, UInt32(pointer.count))
        }
        guard length > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { pointer in
            pointer.baseAddress.map(String.init(cString:))
        }
    }

    private func bundleIdentifier(forExecutablePath path: String) -> String? {
        guard let range = path.range(of: ".app/", options: .caseInsensitive) else { return nil }
        let bundlePath = String(path[..<range.lowerBound]) + ".app"
        return Bundle(path: bundlePath)?.bundleIdentifier
    }

    static func isKnownTerminalOrIDE(_ bundleIdentifier: String) -> Bool {
        let identifiers: Set<String> = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.microsoft.VSCode",
            "com.todesktop.230313mzl4w4u92",
            "dev.zed.Zed",
            "com.github.wez.wezterm",
            "net.kovidgoyal.kitty",
            "com.mitchellh.ghostty",
            "dev.warp.Warp-Stable"
        ]
        return identifiers.contains(bundleIdentifier)
    }
}
