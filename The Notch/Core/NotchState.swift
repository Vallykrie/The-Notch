import Foundation

enum NotchState: Equatable {
    case collapsed
    case expanded
}

/// Which panel the *expanded* notch is showing.
///
/// This used to be `shell` / `agents`, where the shell was a resting surface of system
/// widgets and the agent surface took over only while an approval was blocking. That was
/// wrong twice over: the system widgets were not what the app is for, and gating the agent
/// surface on approvals meant a working, thinking or compacting agent — the normal case —
/// never appeared anywhere.
///
/// Collapsed, both live activities are on screen at once, on opposite shoulders. This enum
/// only decides which one the expanded panel elaborates, and the user switches it directly.
enum NotchSurface: String, Equatable, CaseIterable, Identifiable {
    case media
    case agents
    case trading
    case calendar
    case notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .media: "Media"
        case .agents: "Agents"
        case .trading: "Crypto"
        case .calendar: "Calendar"
        case .notes: "Notes"
        }
    }

    /// The tab's sprite, shown instead of its name once the tab bar is too crowded for names.
    var glyph: PixelGlyph {
        switch self {
        case .media: .musicNote
        case .agents: .chip
        case .trading: .coin
        case .calendar: .calendar
        case .notes: .pencil
        }
    }
}
