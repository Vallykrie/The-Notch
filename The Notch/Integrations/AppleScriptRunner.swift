import Darwin
import Foundation

nonisolated enum AppleScriptRunnerError: Error, Equatable, Sendable {
    case automationPermissionDenied
    case timedOut(seconds: TimeInterval)
    case launchFailed(String)
    case executionFailed(status: Int32, message: String)
}

nonisolated struct AppleScriptOutput: Equatable, Sendable {
    let standardOutput: String
    let standardError: String
}

/// Executes `osascript` on a worker queue. The child is terminated, then killed if necessary,
/// before a timeout result is returned, so it cannot remain behind after the caller continues.
nonisolated struct AppleScriptRunner: Sendable {
    let timeout: TimeInterval

    init(timeout: TimeInterval = 3) {
        self.timeout = max(0.1, timeout)
    }

    func run(_ source: String) async throws -> AppleScriptOutput {
        let timeout = timeout
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try Self.execute(source, timeout: timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func execute(_ source: String, timeout: TimeInterval) throws -> AppleScriptOutput {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            throw AppleScriptRunnerError.launchFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(0.25)
            while process.isRunning && Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw AppleScriptRunnerError.timedOut(seconds: timeout)
        }

        process.waitUntilExit()
        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: outputData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = String(decoding: errorData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            if message.contains("-1743") || message.localizedCaseInsensitiveContains("not permitted") {
                throw AppleScriptRunnerError.automationPermissionDenied
            }
            throw AppleScriptRunnerError.executionFailed(
                status: process.terminationStatus,
                message: message
            )
        }
        return AppleScriptOutput(standardOutput: output, standardError: message)
    }
}

nonisolated enum AppleScriptLiteral {
    static func string(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
