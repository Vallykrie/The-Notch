import AppKit
import Foundation

@MainActor
struct URLSchemeStrategy: TerminalJumpStrategy {
    let identifier = JumpStrategyID.urlScheme

    func attempt(target: JumpTarget, bundleIdentifier: String?) async -> StrategyAttempt {
        guard let application = Self.application(bundleIdentifier: bundleIdentifier,
                                                 termProgram: target.termProgram) else {
            return .notApplicable
        }
        guard !target.cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              var components = URLComponents() as URLComponents? else {
            return .noMatch
        }
        components.scheme = application.scheme
        components.host = "file"
        components.path = URL(fileURLWithPath: target.cwd).standardizedFileURL.path
        guard let url = components.url, NSWorkspace.shared.open(url) else {
            return .failed(
                .strategyFailed(strategy: identifier, message: "Could not open \(application.scheme) URL")
            )
        }
        return .approximate(bundleIdentifier: application.bundleIdentifier)
    }

    private static func application(bundleIdentifier: String?, termProgram: String?)
        -> (scheme: String, bundleIdentifier: String)? {
        switch bundleIdentifier {
        case "com.microsoft.VSCode": return ("vscode", "com.microsoft.VSCode")
        case "com.todesktop.230313mzl4w4u92": return ("cursor", "com.todesktop.230313mzl4w4u92")
        case "dev.zed.Zed": return ("zed", "dev.zed.Zed")
        default: break
        }
        switch termProgram?.lowercased() {
        case "vscode": return ("vscode", "com.microsoft.VSCode")
        case "cursor": return ("cursor", "com.todesktop.230313mzl4w4u92")
        case "zed": return ("zed", "dev.zed.Zed")
        default: return nil
        }
    }
}
