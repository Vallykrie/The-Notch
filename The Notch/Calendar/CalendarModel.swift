import CoreGraphics
import Foundation

/// One event occurrence, as the calendar panel draws it.
///
/// A value copy of the `EKEvent` rather than the event itself: `EKEvent` is a live, mutable
/// object owned by an `EKEventStore`, and handing it to SwiftUI means every refresh the store
/// makes can mutate something a view is halfway through drawing.
nonisolated struct CalendarEvent: Identifiable, Equatable, Sendable {
    /// Unique per *occurrence*. A repeating event's occurrences share an `eventIdentifier`, so
    /// the start date is folded in, or a weekly standup would collapse into one row.
    let id: String
    /// What Calendar.app needs to show the event. `nil` for preview data.
    let eventIdentifier: String?
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarTitle: String
    /// The account the calendar belongs to — "iCloud", "you@gmail.com", "Exchange".
    let accountTitle: String
    let color: CGColor?
    let location: String?
    /// A video-call link found in the event, if there is one.
    let meetingURL: URL?

    func isHappening(at date: Date) -> Bool {
        start <= date && date < end
    }

    /// All-day events first, then by start time, then by title so two events at the same minute
    /// never swap places between refreshes.
    static func order(_ lhs: CalendarEvent, _ rhs: CalendarEvent) -> Bool {
        if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        return lhs.title.localizedCompare(rhs.title) == .orderedAscending
    }
}

/// One calendar the user can show or hide, grouped in settings by its account.
nonisolated struct CalendarSource: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let accountTitle: String
    let color: CGColor?
}

nonisolated enum CalendarAccess: Equatable, Sendable {
    /// Never asked. The panel offers a button; nothing asks on its own.
    case undetermined
    case granted
    /// Denied or restricted. Only System Settings can change it now.
    case denied
}

/// The span of weeks the panel's week strip can page through, and the day arithmetic it needs.
///
/// A fixed span rather than an endless strip: EventKit is queried once for the whole of it, so
/// paging between weeks never waits on a fetch, and ten weeks is far more than anyone pages
/// through from the top of the screen.
nonisolated enum CalendarWeeks {
    static let weeksBack = 2
    static let weeksAhead = 8

    /// The first day of the week holding `date`, honouring the user's first weekday.
    static func startOfWeek(for date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// The first day of every week the strip offers, oldest first.
    static func weekStarts(around now: Date, calendar: Calendar = .current) -> [Date] {
        let current = startOfWeek(for: now, calendar: calendar)
        return (-weeksBack...weeksAhead).compactMap { offset in
            calendar.date(byAdding: .weekOfYear, value: offset, to: current)
        }
    }

    /// From the first day of the earliest week to the end of the last one.
    static func window(around now: Date, calendar: Calendar = .current) -> DateInterval {
        let weeks = weekStarts(around: now, calendar: calendar)
        let start = weeks.first ?? calendar.startOfDay(for: now)
        let last = weeks.last ?? start
        let end = calendar.date(byAdding: .day, value: 7, to: last) ?? last.addingTimeInterval(7 * 86_400)
        return DateInterval(start: start, end: end)
    }

    /// The seven days of the week starting at `start`.
    static func days(ofWeekStarting start: Date, calendar: Calendar = .current) -> [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// Every event filed under each day it touches, keyed by the start of that day. An event
    /// running from 23:00 to 01:00 is listed on both days, as Calendar.app lists it.
    static func groupByDay(_ events: [CalendarEvent], calendar: Calendar = .current) -> [Date: [CalendarEvent]] {
        var byDay: [Date: [CalendarEvent]] = [:]
        for event in events {
            var day = calendar.startOfDay(for: event.start)
            // An event ending exactly at midnight does not touch the next day.
            while day < event.end || day == calendar.startOfDay(for: event.start) {
                byDay[day, default: []].append(event)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return byDay.mapValues { $0.sorted(by: CalendarEvent.order) }
    }
}

/// Finds the video-call link in an event.
///
/// Calendar providers do not agree on where it goes: Google puts Meet in the event URL and the
/// notes, Outlook puts Teams in the notes, Zoom invites put it in the location. So every field is
/// searched, and only hosts that are actually meeting services count — a notes field full of
/// agenda links must not turn "Join" into a button that opens a Google Doc.
nonisolated enum MeetingLink {
    static let hosts = [
        "zoom.us",
        "zoomgov.com",
        "meet.google.com",
        "teams.microsoft.com",
        "teams.live.com",
        "webex.com",
        "whereby.com",
        "meet.jit.si",
        "chime.aws",
        "gotomeeting.com",
        "facetime.apple.com",
        "slack.com",
    ]

    static func find(url: URL?, location: String?, notes: String?) -> URL? {
        if let url, isMeeting(url) { return url }
        for text in [location, notes].compactMap({ $0 }) where !text.isEmpty {
            if let link = links(in: text).first(where: isMeeting) { return link }
        }
        return nil
    }

    static func isMeeting(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return false }
        // Slack only counts for huddle links, not every message permalink.
        if host.hasSuffix("slack.com") { return url.path.contains("/huddle") }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static func links(in text: String) -> [URL] {
        guard let detector else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap(\.url)
    }
}
