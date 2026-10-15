import AppKit

/// The groups of now-playing sources the user can switch on and off in settings.
nonisolated enum MediaSourceKind: String, CaseIterable, Hashable, Sendable {
    case spotify
    case music
    /// A web browser, whatever site plays in it: YouTube, YouTube Music, Spotify Web.
    case browser
    /// Any other app that publishes Now Playing: podcast apps, other music apps, video players.
    case other

    /// Bundle identifiers of the browsers The Notch knows. A browser missing here still shows,
    /// as `.other`, so leaving one out only changes which switch controls it.
    static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "company.thebrowser.Browser", // Arc
        "company.thebrowser.dia",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "com.operasoftware.Opera",
        "com.operasoftware.OperaGX",
        "com.vivaldi.Vivaldi",
        "app.zen-browser.zen",
        "com.kagi.kagimacOS", // Orion
        "com.duckduckgo.macos.browser",
        "ai.perplexity.comet",
    ]
}

extension NowPlayingStatus.Player {
    nonisolated var sourceKind: MediaSourceKind {
        switch self {
        case .spotify:
            .spotify
        case .music:
            .music
        case let .app(bundleIdentifier):
            MediaSourceKind.browserBundleIdentifiers.contains(bundleIdentifier) ? .browser : .other
        }
    }

    /// The name to show for this player: the app's own localised name, looked up once per
    /// bundle identifier. Falls back to a generic label for an app that cannot be found.
    var displayName: String {
        switch self {
        case .spotify:
            "Spotify"
        case .music:
            "Apple Music"
        case let .app(bundleIdentifier):
            AppNameCache.shared.name(for: bundleIdentifier)
                ?? (sourceKind == .browser ? "Browser" : "Now Playing")
        }
    }
}

/// Launch Services lookups are file-system work, and the badge's label is read on every render.
@MainActor
private final class AppNameCache {
    static let shared = AppNameCache()

    private var names: [String: String?] = [:]

    func name(for bundleIdentifier: String) -> String? {
        if let cached = names[bundleIdentifier] { return cached }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .map { FileManager.default.displayName(atPath: $0.path) }
            .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
        names[bundleIdentifier] = name
        return name
    }
}
