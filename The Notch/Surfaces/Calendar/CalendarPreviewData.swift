import CoreGraphics
import Foundation

/// Calendar stores for previews and `FrameDump`. Never backed by EventKit.
@MainActor
enum CalendarPreviewData {
    static func emptyStore(access: CalendarAccess = .undetermined) -> CalendarStore {
        CalendarStore(preview: [], calendars: [], access: access)
    }

    static func populatedStore(now: Date = Date()) -> CalendarStore {
        let work = CGColor(red: 0.27, green: 0.55, blue: 0.98, alpha: 1)
        let personal = CGColor(red: 0.98, green: 0.62, blue: 0.20, alpha: 1)
        let team = CGColor(red: 0.42, green: 0.82, blue: 0.45, alpha: 1)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)

        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }

        func event(_ title: String, _ start: Date, minutes: Int, account: String, color: CGColor, allDay: Bool = false, meeting: String? = nil) -> CalendarEvent {
            CalendarEvent(
                id: "\(title)@\(start.timeIntervalSinceReferenceDate)",
                eventIdentifier: nil,
                title: title,
                start: start,
                end: start.addingTimeInterval(Double(minutes) * 60),
                isAllDay: allDay,
                calendarTitle: account,
                accountTitle: account,
                color: color,
                location: nil,
                meetingURL: meeting.flatMap(URL.init(string:))
            )
        }

        let soon = now.addingTimeInterval(12 * 60)
        let events = [
            event("Design review", soon, minutes: 45, account: "Google", color: work, meeting: "https://meet.google.com/abc-defg-hij"),
            event("1:1 with Sam", soon.addingTimeInterval(90 * 60), minutes: 30, account: "Outlook", color: team, meeting: "https://teams.microsoft.com/l/meetup-join/x"),
            event("Gym", at(1, 7, 30), minutes: 60, account: "iCloud", color: personal),
            event("Sprint planning", at(1, 10), minutes: 60, account: "Outlook", color: team),
            event("Dentist", at(2, 15), minutes: 30, account: "iCloud", color: personal),
        ].sorted(by: CalendarEvent.order)

        let sources = [
            CalendarSource(id: "google", title: "Work", accountTitle: "you@gmail.com", color: work),
            CalendarSource(id: "icloud", title: "Personal", accountTitle: "iCloud", color: personal),
            CalendarSource(id: "outlook", title: "Calendar", accountTitle: "Outlook", color: team),
        ]
        return CalendarStore(preview: events, calendars: sources)
    }
}
