import Foundation

@MainActor
struct TerminalAppStrategy: TerminalJumpStrategy {
    let identifier = JumpStrategyID.terminalApp
    private let runner: AppleScriptRunner

    init(runner: AppleScriptRunner) {
        self.runner = runner
    }

    func attempt(target: JumpTarget, bundleIdentifier: String?) async -> StrategyAttempt {
        let isTerminal = bundleIdentifier == "com.apple.Terminal"
            || target.termProgram?.lowercased() == "apple_terminal"
        guard isTerminal else { return .notApplicable }
        let terminalIdentifiers = [target.tty, target.termSessionID].compactMap { $0 }
        guard !terminalIdentifiers.isEmpty else { return .noMatch }

        let wantedIdentifiers = terminalIdentifiers
            .map(AppleScriptLiteral.string)
            .joined(separator: ", ")
        let script = """
        tell application id "com.apple.Terminal"
            set wantedIdentifiers to {\(wantedIdentifiers)}
            repeat with candidateWindow in windows
                repeat with candidateTab in tabs of candidateWindow
                    set identifierMatched to false
                    try
                        set identifierMatched to (wantedIdentifiers contains (tty of candidateTab as text))
                    end try
                    if identifierMatched then
                        set selected tab of candidateWindow to candidateTab
                        set index of candidateWindow to 1
                        activate
                        return "MATCHED"
                    end if
                end repeat
            end repeat
            return "NO_MATCH"
        end tell
        """

        do {
            let output = try await runner.run(script)
            return output.standardOutput == "MATCHED"
                ? .exact(bundleIdentifier: "com.apple.Terminal")
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
            .failed(.automationPermissionDenied(bundleIdentifier: "com.apple.Terminal"))
        case .timedOut:
            .failed(.strategyTimedOut(strategy: .terminalApp))
        case .launchFailed(let message), .executionFailed(_, let message):
            .failed(.strategyFailed(strategy: .terminalApp, message: message))
        }
    }
}
