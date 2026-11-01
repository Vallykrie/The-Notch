import Combine
import Foundation

/// The Pomodoro timer behind the Focus tab.
///
/// The clock is an *end date*, not a tick count. A count drifts every time the main thread is
/// busy and stops dead while the Mac sleeps; an end date is right after either, and the
/// remaining time is just arithmetic against now. The one timer this object schedules only
/// exists to notice the end date passing while nobody is looking at the panel.
///
/// Durations are set in the panel (the two rulers) and remembered between launches. The
/// shape of a set — how many rounds, the long break, what starts by itself — is a preference
/// and is read from `NotchSettings` at the moment each phase ends, so changing it mid-set
/// takes effect at the next boundary rather than rewriting the phase in progress.
@MainActor
final class FocusTimer: ObservableObject {
    enum Phase: Equatable {
        case focus
        case shortBreak
        case longBreak

        var isBreak: Bool { self != .focus }
    }

    enum Run: Equatable {
        /// Nothing started: the panel shows the rulers.
        case setup
        case running
        case paused
        /// A phase is loaded but not started, because auto-start is off for it.
        case waiting
    }

    static let focusRange = 5 ... 90
    static let breakRange = 1 ... 30

    @Published private(set) var phase: Phase = .focus
    @Published private(set) var round = 1
    @Published private(set) var run: Run = .setup
    @Published var focusMinutes: Int {
        didSet { defaults?.set(focusMinutes, forKey: Key.focusMinutes) }
    }
    @Published var breakMinutes: Int {
        didSet { defaults?.set(breakMinutes, forKey: Key.breakMinutes) }
    }
    /// Focus rounds finished on `countedDay`. Read through `completed(on:)`, which knows that a
    /// count from yesterday is zero today.
    @Published private(set) var completedToday = 0
    /// When the current phase was started (or resumed into its first second), for the hop.
    @Published private(set) var startedAt: Date?
    /// The phase that just ended, and when — what the celebration and the round-end card show.
    @Published private(set) var lastEnded: Ended?

    struct Ended: Equatable {
        let phase: Phase
        let at: Date
    }

    /// Called once per phase that runs out on its own (not skipped): the chime and the card.
    var onPhaseEnded: ((Phase) -> Void)?

    private let settings: NotchSettings
    private let defaults: UserDefaults?
    private var endDate: Date?
    /// Remaining seconds while paused or waiting.
    private var heldRemaining: TimeInterval = 0
    private var expiry: Timer?
    private var countedDay: Date?

    init(settings: NotchSettings, defaults: UserDefaults? = .standard) {
        self.settings = settings
        self.defaults = defaults
        let focus = defaults?.object(forKey: Key.focusMinutes) as? Int ?? 25
        let brk = defaults?.object(forKey: Key.breakMinutes) as? Int ?? 5
        focusMinutes = focus.clamped(to: Self.focusRange)
        breakMinutes = brk.clamped(to: Self.breakRange)
        if let day = defaults?.object(forKey: Key.countedDay) as? Date,
           Calendar.current.isDateInToday(day) {
            countedDay = day
            completedToday = defaults?.integer(forKey: Key.completedToday) ?? 0
        }
    }

    // MARK: Reading

    /// Whether a session exists at all — what the notch shoulders ask.
    var isActive: Bool { run != .setup }

    var rounds: Int { settings.focusRounds.count }

    /// Focus rounds finished on the day of `now`. Skipped rounds do not count.
    func completed(on now: Date = Date()) -> Int {
        guard let countedDay, Calendar.current.isDate(countedDay, inSameDayAs: now) else { return 0 }
        return completedToday
    }

    /// The long break this set ends with, in minutes, or `nil` when there is none.
    var longBreakMinutes: Int? {
        switch settings.focusLongBreak {
        case .auto: Self.longBreakMinutes(for: breakMinutes)
        case .off: nil
        case .fifteen: 15
        case .thirty: 30
        }
    }

    /// The Auto rule: three times the break, rounded to five, between 10 and 45 minutes — and
    /// none at all once the break is 15 minutes or longer, because that break is already long.
    static func longBreakMinutes(for breakMinutes: Int) -> Int? {
        guard breakMinutes < 15 else { return nil }
        let tripled = (Double(breakMinutes) * 3 / 5).rounded() * 5
        return min(45, max(10, Int(tripled)))
    }

    func duration(of phase: Phase) -> TimeInterval {
        let minutes = switch phase {
        case .focus: focusMinutes
        case .shortBreak: breakMinutes
        case .longBreak: longBreakMinutes ?? breakMinutes
        }
        return TimeInterval(minutes) * Self.secondsPerMinute
    }

    func remaining(at now: Date = Date()) -> TimeInterval {
        switch run {
        case .setup: duration(of: .focus)
        case .running: max(0, (endDate ?? now).timeIntervalSince(now))
        case .paused, .waiting: heldRemaining
        }
    }

    /// How far through the current phase, 0 to 1.
    func progress(at now: Date = Date()) -> Double {
        let total = duration(of: phase)
        guard total > 0, run != .setup else { return 0 }
        return min(1, max(0, 1 - remaining(at: now) / total))
    }

    /// The set as a sequence of phases, for the strip.
    var plan: [Phase] {
        (1 ... rounds).flatMap { round -> [Phase] in
            if round == rounds { [.focus, longBreakMinutes == nil ? .shortBreak : .longBreak] }
            else { [.focus, .shortBreak] }
        }
    }

    /// Where the current phase sits in `plan`.
    var planIndex: Int {
        (round - 1) * 2 + (phase == .focus ? 0 : 1)
    }

    /// When the whole set will end if nothing is paused from here on.
    func setEnds(at now: Date = Date()) -> Date {
        let later = plan.dropFirst(planIndex + 1).reduce(0) { $0 + duration(of: $1) }
        return now.addingTimeInterval(remaining(at: now) + later)
    }

    // MARK: Control

    /// Start from the rulers, start a waiting phase, pause, or resume — the one button.
    func toggle(now: Date = Date()) {
        switch run {
        case .setup:
            phase = .focus
            round = 1
            begin(remaining: duration(of: .focus), now: now)
        case .waiting:
            begin(remaining: heldRemaining, now: now)
        case .running:
            heldRemaining = remaining(at: now)
            endDate = nil
            run = .paused
            expiry?.invalidate()
        case .paused:
            begin(remaining: heldRemaining, now: now, hop: false)
        }
    }

    /// Ends the phase early. A skipped focus round does not count as done.
    func skip(now: Date = Date()) {
        guard run != .setup else { return }
        let wasRunning = run == .running
        advance(completed: false, now: now)
        if run == .running, !wasRunning {
            // Skipping while paused should not start the clock behind the user's back.
            heldRemaining = remaining(at: now)
            endDate = nil
            run = .paused
            expiry?.invalidate()
        }
    }

    /// Back to the rulers.
    func reset() {
        expiry?.invalidate()
        expiry = nil
        endDate = nil
        phase = .focus
        round = 1
        run = .setup
        startedAt = nil
        lastEnded = nil
    }

    // MARK: Phases

    private func begin(remaining: TimeInterval, now: Date, hop: Bool = true) {
        endDate = now.addingTimeInterval(remaining)
        run = .running
        if hop { startedAt = now }
        schedule()
    }

    private func schedule() {
        expiry?.invalidate()
        guard let endDate else { return }
        let timer = Timer(fire: endDate, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.expire() }
        }
        // Common modes, so the phase still ends while a menu is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        expiry = timer
    }

    private func expire() {
        guard run == .running, let endDate, endDate.timeIntervalSinceNow <= 0.05 else {
            schedule()
            return
        }
        advance(completed: true, now: Date())
    }

    private func advance(completed: Bool, now: Date) {
        let ended = phase
        if ended == .focus {
            if completed { countRound(now: now) }
            phase = round >= rounds ? (longBreakMinutes == nil ? .shortBreak : .longBreak) : .shortBreak
        } else {
            round = round >= rounds ? 1 : round + 1
            phase = .focus
        }

        let autoStart = phase.isBreak ? settings.focusAutoStartBreaks : settings.focusAutoStartRounds
        if autoStart {
            begin(remaining: duration(of: phase), now: now, hop: phase == .focus)
        } else {
            expiry?.invalidate()
            endDate = nil
            heldRemaining = duration(of: phase)
            run = .waiting
        }

        if completed {
            lastEnded = Ended(phase: ended, at: now)
            onPhaseEnded?(ended)
        }
    }

    private func countRound(now: Date) {
        if let countedDay, !Calendar.current.isDate(countedDay, inSameDayAs: now) {
            completedToday = 0
        }
        completedToday += 1
        countedDay = now
        defaults?.set(completedToday, forKey: Key.completedToday)
        defaults?.set(now, forKey: Key.countedDay)
    }

    /// Real minutes, except in a debug build launched with `NOTCH_FOCUS_SECONDS_PER_MINUTE`, which
    /// makes a whole set testable in a couple of minutes.
    static let secondsPerMinute: TimeInterval = {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["NOTCH_FOCUS_SECONDS_PER_MINUTE"],
           let seconds = TimeInterval(value), seconds > 0 {
            return seconds
        }
        #endif
        return 60
    }()

    private enum Key {
        static let focusMinutes = "NotchFocusMinutes"
        static let breakMinutes = "NotchFocusBreakMinutes"
        static let completedToday = "NotchFocusCompletedToday"
        static let countedDay = "NotchFocusCountedDay"
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
