import Foundation

@main
struct CalendarTests {
    static var failures = 0

    static func check(_ condition: Bool, _ name: String) {
        print("\(condition ? "PASS" : "FAIL"): \(name)")
        if !condition { failures += 1 }
    }

    static func main() {
        // Meeting links: found wherever the provider put them, and only real meeting hosts.
        let meet = URL(string: "https://meet.google.com/abc-defg-hij")!
        check(MeetingLink.find(url: meet, location: nil, notes: nil) == meet, "Google Meet in the event URL")
        check(
            MeetingLink.find(url: nil, location: nil, notes: "Agenda: https://docs.google.com/x\nJoin: https://teams.microsoft.com/l/meetup-join/19%3a")?.host == "teams.microsoft.com",
            "Teams link in notes wins over an agenda doc"
        )
        check(MeetingLink.find(url: nil, location: "https://us02web.zoom.us/j/123", notes: nil)?.host == "us02web.zoom.us", "Zoom subdomain in location")
        check(MeetingLink.find(url: URL(string: "https://example.com/meeting"), location: "Room 4", notes: "bring snacks") == nil, "no meeting host, no link")
        check(MeetingLink.find(url: URL(string: "https://evilzoom.us/j/1"), location: nil, notes: nil) == nil, "lookalike host rejected")
        check(!MeetingLink.isMeeting(URL(string: "https://acme.slack.com/archives/C1")!), "Slack permalink is not a meeting")
        check(MeetingLink.isMeeting(URL(string: "https://app.slack.com/huddle/T1/C1")!), "Slack huddle is a meeting")

        // Week span: whole weeks, starting on the calendar's first weekday.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2 // Monday
        let iso = ISO8601DateFormatter()
        let now = iso.date(from: "2026-10-14T15:30:00Z")! // a Wednesday
        check(CalendarWeeks.startOfWeek(for: now, calendar: calendar) == iso.date(from: "2026-10-12T00:00:00Z")!, "week starts on Monday 12th")
        let weeks = CalendarWeeks.weekStarts(around: now, calendar: calendar)
        check(weeks.count == CalendarWeeks.weeksBack + CalendarWeeks.weeksAhead + 1, "one entry per week in the span")
        let window = CalendarWeeks.window(around: now, calendar: calendar)
        check(window.duration == Double(weeks.count * 7) * 86_400, "window covers every week whole")
        check(CalendarWeeks.days(ofWeekStarting: weeks[0], calendar: calendar).count == 7, "a week has seven days")

        // Ordering: all-day first within a day, then by start, then by title.
        func event(_ title: String, _ offset: TimeInterval, allDay: Bool = false) -> CalendarEvent {
            let start = now.addingTimeInterval(offset)
            return CalendarEvent(id: title, eventIdentifier: nil, title: title, start: start, end: start.addingTimeInterval(1800), isAllDay: allDay, calendarTitle: "", accountTitle: "", color: nil, location: nil, meetingURL: nil)
        }
        let sorted = [event("B", 60), event("Holiday", 0, allDay: true), event("A", 60)]
            .sorted(by: CalendarEvent.order)
            .map(\.title)
        check(sorted == ["Holiday", "A", "B"], "day order: all-day, then start, then title")
        check(event("Now", -60).isHappening(at: now), "an event under way is happening")
        check(!event("Later", 60).isHappening(at: now), "a future event is not")


        // Grouping: an event touching two days is listed on both; one ending at midnight is not.
        let lateNight = CalendarEvent(id: "late", eventIdentifier: nil, title: "Late", start: iso.date(from: "2026-10-14T23:00:00Z")!, end: iso.date(from: "2026-10-15T01:00:00Z")!, isAllDay: false, calendarTitle: "", accountTitle: "", color: nil, location: nil, meetingURL: nil)
        let toMidnight = CalendarEvent(id: "eve", eventIdentifier: nil, title: "Evening", start: iso.date(from: "2026-10-14T22:00:00Z")!, end: iso.date(from: "2026-10-15T00:00:00Z")!, isAllDay: false, calendarTitle: "", accountTitle: "", color: nil, location: nil, meetingURL: nil)
        let byDay = CalendarWeeks.groupByDay([lateNight, toMidnight], calendar: calendar)
        let wed = iso.date(from: "2026-10-14T00:00:00Z")!, thu = iso.date(from: "2026-10-15T00:00:00Z")!
        check(byDay[wed]?.map(\.id) == ["eve", "late"], "both evening events on Wednesday, in order")
        check(byDay[thu]?.map(\.id) == ["late"], "only the one past midnight on Thursday")
        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("all calendar checks passed")
    }
}
