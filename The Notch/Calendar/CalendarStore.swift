import AppKit
import Combine
import EventKit

/// The user's upcoming events, from every calendar account on this Mac.
///
/// Reads EventKit and nothing else. That is how one feature covers Apple, Google and Microsoft
/// at once: macOS already syncs iCloud, Google, Exchange / Outlook.com and any CalDAV account
/// added in System Settings › Internet Accounts into the same store Calendar.app reads. Talking
/// to Google's and Microsoft's APIs directly would mean shipping OAuth client secrets in an open
/// source app and holding the user's tokens; EventKit means holding neither.
///
/// Nothing here asks for permission by itself. The panel offers a button, and `requestAccess()`
/// is the only path to the prompt — the same rule the rest of the app keeps for TCC.
@MainActor
final class CalendarStore: ObservableObject {
    @Published private(set) var access: CalendarAccess
    /// Events still to come (or under way) within ``range``, in display order.
    @Published private(set) var events: [CalendarEvent] = []
    /// Every event calendar on the Mac, hidden ones included, for the settings list.
    @Published private(set) var calendars: [CalendarSource] = []
    /// Calendars the user switched off. Stored as hidden rather than shown, so a calendar added
    /// to the Mac later appears by default.
    @Published private(set) var hiddenCalendarIDs: Set<String>

    var range: CalendarRange = .default {
        didSet { if oldValue != range { refresh() } }
    }

    var showsAllDay = true {
        didSet { if oldValue != showsAllDay { refresh() } }
    }

    /// `nil` for preview stores, which must never touch the user's real calendars.
    private let eventStore: EKEventStore?
    private let defaults: UserDefaults
    private var isSuspended = true
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var ticker: Timer?

    private static let hiddenKey = "NotchCalendarHiddenIDs"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        eventStore = EKEventStore()
        access = Self.currentAccess()
        hiddenCalendarIDs = Set(defaults.stringArray(forKey: Self.hiddenKey) ?? [])
    }

    /// Fixed content for previews and `FrameDump`.
    init(preview events: [CalendarEvent], calendars: [CalendarSource], access: CalendarAccess = .granted) {
        defaults = UserDefaults(suiteName: "com.thenotch.TheNotch.ephemeral") ?? .standard
        eventStore = nil
        self.access = access
        self.events = events
        self.calendars = calendars
        hiddenCalendarIDs = []
    }

    deinit {
        ticker?.invalidate()
        for (center, token) in observers { center.removeObserver(token) }
    }

    // MARK: Lifecycle

    /// Off stops every observer and the minute ticker and forgets the events, so a switched-off
    /// feature holds nothing of the user's calendar in memory. Idempotent.
    func setSuspended(_ suspended: Bool) {
        guard eventStore != nil, suspended != isSuspended else { return }
        isSuspended = suspended
        if suspended {
            stopObserving()
            events = []
            calendars = []
        } else {
            access = Self.currentAccess()
            startObserving()
            refresh()
        }
    }

    /// Asks macOS for calendar access, or — once the user has said no — opens the pane where
    /// they can change their mind, since the prompt will never appear a second time.
    func requestAccess() {
        guard let eventStore else { return }
        switch access {
        case .granted:
            refresh()
        case .denied:
            Self.openPrivacySettings()
        case .undetermined:
            // Activated first: an accessory app's prompt otherwise opens behind whatever the
            // user is working in, and the notch looks like it ignored the click.
            NSApp.activate(ignoringOtherApps: true)
            eventStore.requestFullAccessToEvents { [weak self] _, error in
                if let error { NSLog("The Notch: calendar access request failed: \(error.localizedDescription)") }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    access = Self.currentAccess()
                    refresh()
                }
            }
        }
    }

    // MARK: Reading

    func refresh(now: Date = Date()) {
        guard let eventStore, !isSuspended, access == .granted else { return }

        let all = eventStore.calendars(for: .event)
        calendars = all
            .map { calendar in
                CalendarSource(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    accountTitle: calendar.source?.title ?? "Other",
                    color: calendar.cgColor
                )
            }
            .sorted { ($0.accountTitle, $0.title) < ($1.accountTitle, $1.title) }

        let visible = all.filter { !hiddenCalendarIDs.contains($0.calendarIdentifier) }
        guard !visible.isEmpty else {
            events = []
            return
        }

        let window = range.window(from: now)
        let predicate = eventStore.predicateForEvents(withStart: window.start, end: window.end, calendars: visible)
        let fresh = eventStore.events(matching: predicate)
            .filter { event in
                event.endDate > now
                    && event.status != .canceled
                    && (showsAllDay || !event.isAllDay)
                    && !Self.isDeclined(event)
            }
            .map(Self.snapshot)
            .sorted(by: CalendarEvent.order)
        // Only published when something changed: the ticker refreshes every minute, and a
        // republish of identical events re-renders the panel for nothing.
        if fresh != events { events = fresh }
    }

    /// The event under way now, or failing that the next one to start — timed events only. An
    /// all-day "Office closed" is not what anyone means by "what's next".
    func nextEvent(at now: Date = Date()) -> CalendarEvent? {
        events.first { !$0.isAllDay && $0.end > now }
    }

    // MARK: Calendars

    func isVisible(_ calendarID: String) -> Bool {
        !hiddenCalendarIDs.contains(calendarID)
    }

    func setVisible(_ calendarID: String, _ visible: Bool) {
        if visible {
            hiddenCalendarIDs.remove(calendarID)
        } else {
            hiddenCalendarIDs.insert(calendarID)
        }
        defaults.set(hiddenCalendarIDs.sorted(), forKey: Self.hiddenKey)
        refresh()
    }

    // MARK: Actions

    /// Shows the event in Calendar.app, or just opens Calendar.app if the event cannot be found.
    func open(_ event: CalendarEvent) {
        if let identifier = event.eventIdentifier?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "ical://ekevent/\(identifier)?method=show&options=more"),
           NSWorkspace.shared.open(url) {
            return
        }
        Self.openCalendarApp()
    }

    func join(_ event: CalendarEvent) {
        guard let url = event.meetingURL else { return }
        NSWorkspace.shared.open(url)
    }

    static func openCalendarApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Where Google, Microsoft and other accounts are added. Their calendars then appear here.
    static func openInternetAccounts() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Private

    private func startObserving() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        // A sync from any account, an edit in Calendar.app, midnight, and waking from sleep —
        // the four ways the list goes stale without the user touching the notch.
        //
        // One closure literal per observer rather than one shared `let`: a stored closure is not
        // `@Sendable`, and passing it where `addObserver` wants one is a data-race warning.
        observers = [
            (center, center.addObserver(forName: .EKEventStoreChanged, object: eventStore, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }),
            (center, center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }),
            (workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }),
        ]
        // Once a minute, so a meeting that ended drops off and "in 5 min" counts down. EventKit
        // is a local database; this is a cheap read, not a network call.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopObserving() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        ticker?.invalidate()
        ticker = nil
    }

    private static func currentAccess() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .undetermined
        // Write-only access cannot read a single event, so for this panel it is a refusal.
        case .writeOnly, .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    private static func isDeclined(_ event: EKEvent) -> Bool {
        event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }

    private static func snapshot(_ event: EKEvent) -> CalendarEvent {
        let identifier = event.eventIdentifier ?? UUID().uuidString
        let location = event.location.flatMap { $0.isEmpty ? nil : $0 }
        return CalendarEvent(
            id: "\(identifier)@\(event.startDate.timeIntervalSinceReferenceDate)",
            eventIdentifier: event.eventIdentifier,
            title: event.title?.isEmpty == false ? event.title : "Untitled",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            calendarTitle: event.calendar?.title ?? "",
            accountTitle: event.calendar?.source?.title ?? "",
            color: event.calendar?.cgColor,
            location: location,
            meetingURL: MeetingLink.find(url: event.url, location: location, notes: event.notes)
        )
    }
}
