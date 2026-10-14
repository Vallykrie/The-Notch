import SwiftUI

/// The calendar panel: today and what is next on the left, the agenda on the right.
///
/// The same two columns either side of a hairline as the crypto panel, so switching tabs moves
/// content rather than rearranging the panel. The left column answers the only question anyone
/// glances at a calendar for — "what's next, and when?" — and offers Join when the event has a
/// video-call link, which is the one action worth taking from the top of the screen.
@MainActor
struct CalendarExpandedView: View {
    @ObservedObject var store: CalendarStore

    var body: some View {
        // Half a minute is fine-grained enough for "in 5 min" and costs nothing.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .foregroundStyle(Theme.Colors.textPrimary)
        .padding(.horizontal, Theme.Metrics.expandedHorizontalPadding + Theme.Metrics.CalendarPanel.contentInset)
        .padding(.bottom, Theme.Metrics.expandedVerticalPadding)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        switch store.access {
        case .undetermined:
            pitch(
                headline: "See your day from the notch.",
                detail: "Reads the calendars on this Mac. Nothing leaves it.",
                action: "Connect calendars"
            )
        case .denied:
            pitch(
                headline: "Calendar access is off.",
                detail: "Allow The Notch under Privacy › Calendars.",
                action: "Open Privacy Settings"
            )
        case .granted:
            twoColumns {
                today(now: now)
            } right: {
                VStack(alignment: .leading, spacing: Theme.Metrics.CalendarPanel.rowSpacing) {
                    agendaHeader
                    agenda(now: now)
                }
            }
        }
    }

    // MARK: Columns

    private func twoColumns<Left: View, Right: View>(
        alignment: VerticalAlignment = .top,
        @ViewBuilder left: () -> Left,
        @ViewBuilder right: () -> Right
    ) -> some View {
        let left = left()
        let right = right()
        // Centred as one block when it fits; full height with a scrolling agenda when it does
        // not. `ImageRenderer` cannot draw a scroll view, so the first form is also the one the
        // frame dump verifies.
        return ViewThatFits(in: .vertical) {
            columnRow(left, right, alignment: alignment)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: .infinity, alignment: .center)
            columnRow(left, right, alignment: alignment)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func columnRow(_ left: some View, _ right: some View, alignment: VerticalAlignment) -> some View {
        HStack(alignment: alignment, spacing: Theme.Metrics.CalendarPanel.columnSpacing) {
            left.frame(width: Theme.Metrics.CalendarPanel.detailWidth, alignment: .leading)
            Rectangle()
                .fill(Theme.Colors.textTertiary.opacity(Theme.Metrics.CalendarPanel.hairlineOpacity))
                .frame(width: 1)
            right.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Left column

    private func today(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(now.formatted(.dateTime.weekday(.wide)).uppercased())
                    .font(Theme.Text.micro)
                    .foregroundStyle(Theme.Colors.textTertiary)
                Text(now.formatted(.dateTime.day().month(.wide)))
                    .font(Theme.Text.title)
            }

            if let next = store.nextEvent(at: now) {
                nextUp(next, now: now)
            } else {
                Text(store.calendars.isEmpty ? "No calendars on this Mac yet." : "Nothing else coming up.")
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
    }

    private func nextUp(_ event: CalendarEvent, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Self.countdown(to: event, now: now).uppercased())
                .font(Theme.Text.micro)
                .foregroundStyle(event.isHappening(at: now) ? Theme.Colors.tradingUp : Theme.Colors.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                CalendarColorMark(color: event.color)
                Text(event.title)
                    .font(Theme.Text.caption)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(Self.timeRange(event))
                .font(Theme.Text.micro)
                .foregroundStyle(Theme.Colors.textTertiary)
                .lineLimit(1)
            HStack(spacing: 6) {
                if event.meetingURL != nil {
                    Button("Join") { store.join(event) }
                        .buttonStyle(.notchCompact)
                        .help(event.meetingURL?.host ?? "")
                }
                Button("Open") { store.open(event) }
                    .buttonStyle(.notchCompact)
            }
            .padding(.top, 2)
        }
    }

    // MARK: Right column

    private var agendaHeader: some View {
        HStack {
            Text("Upcoming").font(Theme.Text.caption).foregroundStyle(Theme.Colors.textSecondary)
            Text("\(store.events.count) \(store.events.count == 1 ? "event" : "events")")
                .font(Theme.Text.micro)
                .foregroundStyle(Theme.Colors.textTertiary)
            Spacer()
            Button("Calendar", systemImage: "arrow.up.forward") { CalendarStore.openCalendarApp() }
                .help("Open Calendar")
        }
        .font(Theme.Text.micro)
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func agenda(now: Date) -> some View {
        if store.events.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.calendars.isEmpty
                    ? "Add iCloud, Google or Microsoft in Internet Accounts and turn on Calendars."
                    : "Your calendars are clear for the next \(store.range.label.lowercased()).")
                    .font(Theme.Text.micro)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("+ Add an account") { CalendarStore.openInternetAccounts() }
                    .buttonStyle(.notchCompact)
            }
        } else {
            ViewThatFits(in: .vertical) {
                agendaRows(now: now)
                ScrollView { agendaRows(now: now) }.scrollIndicators(.hidden)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// One flat list with the day in a leading column, printed on the first event of each day.
    /// Day headers on lines of their own cost a row per day, and two days of a normal calendar
    /// then no longer fit the panel without scrolling.
    private func agendaRows(now: Date) -> some View {
        let events = store.events
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                let day = Self.listedDay(event, now: now)
                let startsDay = index == 0 || Self.listedDay(events[index - 1], now: now) != day
                row(event, now: now, dayLabel: startsDay ? Self.dayLabel(day, now: now) : nil)
                    .padding(.top, startsDay && index > 0 ? Theme.Metrics.CalendarPanel.daySpacing : 0)
            }
        }
    }

    private func row(_ event: CalendarEvent, now: Date, dayLabel: String?) -> some View {
        Button { store.open(event) } label: {
            HStack(spacing: 7) {
                Text((dayLabel ?? "").uppercased())
                    .font(Theme.Text.micro)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .lineLimit(1)
                    .frame(width: Theme.Metrics.CalendarPanel.dayColumnWidth, alignment: .leading)
                CalendarColorMark(color: event.color)
                Text(event.isAllDay ? "all-day" : event.start.formatted(date: .omitted, time: .shortened))
                    .font(Theme.Text.micro)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .frame(width: Theme.Metrics.CalendarPanel.timeColumnWidth, alignment: .leading)
                Text(event.title)
                    .font(Theme.Text.caption)
                    .foregroundStyle(event.isHappening(at: now) && !event.isAllDay ? Theme.Colors.textPrimary : Theme.Colors.textPrimary.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if event.meetingURL != nil {
                    Image(systemName: "video")
                        .font(Theme.Text.micro)
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
                Text(event.accountTitle)
                    .font(Theme.Text.micro)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .lineLimit(1)
                    .frame(maxWidth: Theme.Metrics.CalendarPanel.accountMaxWidth, alignment: .trailing)
            }
            .padding(.horizontal, Theme.Metrics.CalendarPanel.rowHorizontalPadding)
            .padding(.vertical, Theme.Metrics.CalendarPanel.rowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(CalendarRowStyle())
        .help("\(event.title) — \(Self.timeRange(event)) · \(event.calendarTitle)")
        .accessibilityLabel("\(event.title), \(Self.timeRange(event))")
    }

    // MARK: States

    private func pitch(headline: String, detail: String, action: String) -> some View {
        twoColumns(alignment: .center) {
            VStack(alignment: .leading, spacing: 8) {
                Text(headline).font(Theme.Text.title)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(Theme.Text.caption).foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action) { store.requestAccess() }
                    .buttonStyle(.notchCompact)
                    .padding(.top, 2)
            }
        } right: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Works with").font(Theme.Text.micro).foregroundStyle(Theme.Colors.textTertiary)
                ForEach(Self.providers, id: \.self) { provider in
                    Text(provider).font(Theme.Text.caption).foregroundStyle(Theme.Colors.textSecondary)
                }
                Button("+ Add an account…") { CalendarStore.openInternetAccounts() }
                    .font(Theme.Text.micro)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                    .help("Google, Microsoft and other accounts are added in System Settings › Internet Accounts.")
            }
        }
    }

    private static let providers = [
        "Apple iCloud & On My Mac",
        "Google Calendar",
        "Microsoft Outlook / Exchange",
        "Any CalDAV account",
    ]

    // MARK: Formatting

    /// The day an event is listed under. One that began yesterday and runs into today is listed
    /// under today, which is where the user will look for it.
    private static func listedDay(_ event: CalendarEvent, now: Date) -> Date {
        let calendar = Calendar.current
        return max(calendar.startOfDay(for: event.start), calendar.startOfDay(for: now))
    }

    private static func dayLabel(_ day: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(day, inSameDayAs: tomorrow) { return "Tmrw" }
        return day.formatted(.dateTime.weekday(.abbreviated).day())
    }

    static func countdown(to event: CalendarEvent, now: Date) -> String {
        if event.isHappening(at: now) {
            return "Now · ends \(relative(event.end, from: now))"
        }
        let calendar = Calendar.current
        if !calendar.isDate(event.start, inSameDayAs: now) {
            return "Next · \(dayLabel(calendar.startOfDay(for: event.start), now: now))"
        }
        return "Next · \(relative(event.start, from: now))"
    }

    private static func relative(_ date: Date, from now: Date) -> String {
        let minutes = max(0, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        if minutes < 1 { return "now" }
        if minutes < 60 { return "in \(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "in \(hours)h" : "in \(hours)h \(rest)m"
    }

    private static func timeRange(_ event: CalendarEvent) -> String {
        if event.isAllDay { return "All day" }
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        return event.location.map { "\(start) – \(end) · \($0)" } ?? "\(start) – \(end)"
    }
}

/// The calendar's own colour, as a short bar — the same mark Calendar.app uses.
private struct CalendarColorMark: View {
    let color: CGColor?

    var body: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(color.map { Color(cgColor: $0) } ?? Theme.Colors.textTertiary)
            .frame(width: Theme.Metrics.CalendarPanel.colorMarkWidth, height: Theme.Metrics.CalendarPanel.colorMarkHeight)
            .accessibilityHidden(true)
    }
}

/// Hover and press fill for an agenda row, matching the crypto watchlist's selected row.
private struct CalendarRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: Configuration
        @State private var hovered = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Theme.Colors.textPrimary.opacity(configuration.isPressed ? 0.12 : hovered ? 0.08 : 0))
                )
                .onHover { hovered = $0 }
                .animation(Theme.Motion.content, value: hovered)
                .animation(Theme.Motion.content, value: configuration.isPressed)
        }
    }
}
