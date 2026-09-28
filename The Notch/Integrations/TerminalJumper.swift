import AppKit
import Foundation

nonisolated enum JumpStrategyID: String, Equatable, Sendable {
    case iTerm2
    case terminalApp
    case urlScheme
    case applicationActivation
}

nonisolated enum JumpFailure: Error, Equatable, Sendable {
    case noUsableTarget
    case automationPermissionDenied(bundleIdentifier: String)
    case strategyTimedOut(strategy: JumpStrategyID)
    case strategyFailed(strategy: JumpStrategyID, message: String)
    case applicationUnavailable(bundleIdentifier: String)
}

nonisolated enum JumpResult: Equatable, Sendable {
    case exact(strategy: JumpStrategyID, bundleIdentifier: String)
    case approximate(strategy: JumpStrategyID, bundleIdentifier: String)
    case applicationOnly(strategy: JumpStrategyID, bundleIdentifier: String)
    case failed(JumpFailure)
}

nonisolated enum StrategyAttempt: Sendable {
    case notApplicable
    case noMatch
    case exact(bundleIdentifier: String)
    case approximate(bundleIdentifier: String)
    case failed(JumpFailure)
}

/// Extension seam for future terminal-specific exact-match implementations.
@MainActor
protocol TerminalJumpStrategy: Sendable {
    var identifier: JumpStrategyID { get }
    func attempt(target: JumpTarget, bundleIdentifier: String?) async -> StrategyAttempt
}

@MainActor
final class TerminalJumper {
    private let ancestryStrategy: ProcessAncestryStrategy
    private let iTerm2Strategy: ITerm2Strategy
    private let terminalAppStrategy: TerminalAppStrategy
    private let urlSchemeStrategy: URLSchemeStrategy

    init(
        appleScriptRunner: AppleScriptRunner = AppleScriptRunner(),
        ancestryStrategy: ProcessAncestryStrategy = ProcessAncestryStrategy()
    ) {
        self.ancestryStrategy = ancestryStrategy
        self.iTerm2Strategy = ITerm2Strategy(runner: appleScriptRunner)
        self.terminalAppStrategy = TerminalAppStrategy(runner: appleScriptRunner)
        self.urlSchemeStrategy = URLSchemeStrategy()
    }

    func jump(to target: JumpTarget) async -> JumpResult {
        let ancestryStrategy = ancestryStrategy
        let ancestry = await Task.detached(priority: .userInitiated) {
            ancestryStrategy.resolve(from: target)
        }.value
        let bundleIdentifier = target.hintedBundleIdentifier
            ?? ancestry.owningApplicationBundleIdentifier
            ?? Self.bundleIdentifier(forTermProgram: target.termProgram)

        for strategy in [iTerm2Strategy as any TerminalJumpStrategy,
                         terminalAppStrategy as any TerminalJumpStrategy,
                         urlSchemeStrategy as any TerminalJumpStrategy] {
            switch await strategy.attempt(target: target, bundleIdentifier: bundleIdentifier) {
            case .notApplicable, .noMatch:
                continue
            case .exact(let bundleID):
                return .exact(strategy: strategy.identifier, bundleIdentifier: bundleID)
            case .approximate(let bundleID):
                return .approximate(strategy: strategy.identifier, bundleIdentifier: bundleID)
            case .failed(let failure):
                return .failed(failure)
            }
        }

        guard let bundleIdentifier else { return .failed(.noUsableTarget) }
        guard let application = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            return .failed(.applicationUnavailable(bundleIdentifier: bundleIdentifier))
        }
        guard application.activate(options: [.activateAllWindows]) else {
            return .failed(.applicationUnavailable(bundleIdentifier: bundleIdentifier))
        }
        return .applicationOnly(
            strategy: .applicationActivation,
            bundleIdentifier: bundleIdentifier
        )
    }

    private static func bundleIdentifier(forTermProgram termProgram: String?) -> String? {
        switch termProgram?.lowercased() {
        case "iterm.app", "iterm2": "com.googlecode.iterm2"
        case "apple_terminal", "terminal.app": "com.apple.Terminal"
        case "vscode": "com.microsoft.VSCode"
        case "cursor": "com.todesktop.230313mzl4w4u92"
        case "zed": "dev.zed.Zed"
        case "wezterm": "com.github.wez.wezterm"
        case "kitty": "net.kovidgoyal.kitty"
        case "ghostty": "com.mitchellh.ghostty"
        case "warpterminal", "warp": "dev.warp.Warp-Stable"
        default: nil
        }
    }
}
