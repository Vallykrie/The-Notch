import Foundation

@MainActor
struct ITerm2Strategy: TerminalJumpStrategy {
    let identifier = JumpStrategyID.iTerm2
    private let runner: AppleScriptRunner

    init(runner: AppleScriptRunner) {
        self.runner = runner
    }

    func attempt(target: JumpTarget, bundleIdentifier: String?) async -> StrategyAttempt {
        let isITerm = bundleIdentifier == "com.googlecode.iterm2"
            || target.termProgram?.localizedCaseInsensitiveContains("iterm") == true
        guard isITerm || target.iTermSessionID != nil else { return .notApplicable }
        guard let sessionID = target.iTermSessionID else { return .noMatch }

        let wantedID = AppleScriptLiteral.string(sessionID)
        let script = """
        tell application id "com.googlecode.iterm2"
            repeat with candidateWindow in windows
                repeat with candidateTab in tabs of candidateWindow
                    repeat with candidateSession in sessions of candidateTab
                        if (unique ID of candidateSession as text) is \(wantedID) then
                            select candidateSession
                            select candidateTab
                            select candidateWindow
                            activate
                            return "MATCHED"
                        end if
                    end repeat
                end repeat
            end repeat
            return "NO_MATCH"
        end tell
        """

        do {
            let output = try await runner.run(script)
            return output.standardOutput == "MATCHED"
                ? .exact(bundleIdentifier: "com.googlecode.iterm2")
                : .noMatch
        } catch let error as AppleScriptRunnerError {
            return Self.failure(for: error)
        } catch {
            return .failed(.strategyFailed(strategy: identifier, message: error.localizedDescription))
        }
    }

    private static func failure(for error: AppleScriptRunnerError) -> StrategyAttempt {
        switch error {
        case .automationPermissionDenied:
            .failed(.automationPermissionDenied(bundleIdentifier: "com.googlecode.iterm2"))
        case .timedOut:
            .failed(.strategyTimedOut(strategy: .iTerm2))
        case .launchFailed(let message), .executionFailed(_, let message):
            .failed(.strategyFailed(strategy: .iTerm2, message: message))
        }
    }
}
