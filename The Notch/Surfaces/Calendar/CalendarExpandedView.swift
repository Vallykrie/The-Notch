import SwiftUI

/// The calendar panel: a week strip across the top, the selected day's events beneath.
///
/// Concept B from `docs/design/calendar-ui-v1.html`. The strip pages a week at a time — a
/// two-finger swipe on a trackpad, or the arrows on the summary line for a mouse, whose wheel
/// cannot scroll sideways. Each day carries a dot per event in its calendar's colour, so a busy
/// Thursday is visible before it is opened. Clicking a day lists it; today is selected until then.
@MainActor
struct CalendarExpandedView: View {
    @ObservedObject var store: CalendarStore
    @Environment(\.rendersOffscreen) private var rendersOffscreen

    /// `nil` means today, so the selection follows midnight instead of sticking to yesterday.
    @State private var selectedDay: Date?
    /// The first day of the week the strip is showing.
    @State private var visibleWeek: Date? = CalendarWeeks.startOfWeek(for: Date())

    private let calendar = Calendar.current

    var body: some View {
        // Half a minute is fine-grained enough for "in 5 min" and costs nothing.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .foregroundStyle(Theme.Colors.textPrimary)
        .padding(.horizontal, Theme.Metrics.expandedHorizontalPadding)
        .padding(.bottom, Theme.Metrics.expandedVerticalPadding)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        switch store.access {
        case .undetermined:
            pitch(
                headline: "See your week from the notch.",
                detail: "Reads the calendars on this Mac. Nothing leaves it.",
                action: "Connect calendars"
            )
        case .denied:
            pitch(
                headline: "Calendar access is off.",
                detail: "Allow The Notch under Privacy › Calendars.",
                action: "Open privacy settings"
            )
        case .granted:
            let day = selectedDay ?? calendar.startOfDay(for: now)
            VStack(alignment: .leading, spacing: Theme.Metrics.CalendarPanel.sectionSpacing) {
                strip(now: now, selected: day)
                    .frame(height: Theme.Metrics.CalendarPanel.stripHeight)
                summary(for: day, now: now)
                dayList(store.events(on: day), now: now)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: Week strip

    @ViewBuilder
    private func strip(now: Date, selected: Date) -> some View {
        if rendersOffscreen {
            week(CalendarWeeks.startOfWeek(for: now), now: now, selected: selected)
        } else {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(CalendarWeeks.weekStarts(around: now), id: \.self) { start in
                        week(start, now: now, selected: selected)
                            .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.never)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $visibleWeek)
        }
    }

    private func week(_ start: Date, now: Date, selected: Date) -> some View {
        HStack(spacing: Theme.Metrics.CalendarPanel.dayCellSpacing) {
            ForEach(CalendarWeeks.days(ofWeekStarting: start), id: \.self) { day in
                dayCell(day, now: now, isSelected: calendar.isDate(day, inSameDayAs: selected))
            }
        }
    }

    private func dayCell(_ day: Date, now: Date, isSelected: Bool) -> some View {
        let isToday = calendar.isDate(day, inSameDayAs: now)
        let isPast = day < calendar.startOfDay(for: now)
        let events = store.events(on: day)

        return Button {
            withAnimation(Theme.Motion.content) {
                selectedDay = isToday ? nil : day
            }
        } label: {
            VStack(spacing: 2) {
                Text(Self.cellLabel(day).uppercased())
                    .font(Theme.Text.micro)
                    .foregroundStyle(
                        isToday && !isSelected ? Theme.Colors.tradingUp
                            : isSelected ? Theme.Colors.textPrimary
                            : Theme.Colors.textTertiary
                    )
                Text(day.formatted(.dateTime.day()))
                    .font(Theme.Text.body)
                    .monospacedDigit()
                    .foregroundStyle(
                        isSelected || isToday ? Theme.Colors.textPrimary
                            : isPast ? Theme.Colors.textTertiary
                            : Theme.Colors.textSecondary
                    )
                HStack(spacing: Theme.Metrics.CalendarPanel.dayDotSpacing) {
                    ForEach(events.prefix(Theme.Metrics.CalendarPanel.maxDayDots)) { event in
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(Self.color(event.color))
                            .frame(width: Theme.Metrics.CalendarPanel.dayDotSize, height: Theme.Metrics.CalendarPanel.dayDotSize)
                    }
                }
                .frame(height: Theme.Metrics.CalendarPanel.dayDotSize)
                .opacity(isPast && !isSelected ? Theme.Metrics.CalendarPanel.pastOpacity : 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.CalendarPanel.dayCornerRadius, style: .continuous)
                    .fill(Theme.Colors.textPrimary.opacity(isSelected ? Theme.Metrics.CalendarPanel.selectedDayFillOpacity : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Metrics.CalendarPanel.dayCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
        .accessibilityValue("\(events.count) \(events.count == 1 ? "event" : "events")")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: Summary line

    private func summary(for day: Date, now: Date) -> some View {
        let count = store.events(on: day).count
        let isToday = calendar.isDate(day, inSameDayAs: now)
        let thisWeek = CalendarWeeks.startOfWeek(for: now)
        let awayFromToday = !isToday || (!rendersOffscreen && visibleWeek != thisWeek)

        return HStack(spacing: 8) {
            Text("\(day.formatted(.dateTime.weekday(.wide).day().month(.wide))) · \(count) \(count == 1 ? "event" : "events")".uppercased())
                .foregroundStyle(Theme.Colors.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if isToday, let next = store.nextEvent(at: now) {
                Text(Self.countdown(to: next, now: now).uppercased())
                    .foregroundStyle(Theme.Colors.tradingUp)
                    .lineLimit(1)
            }
            if awayFromToday {
                Button("Today") {
                    withAnimation(Theme.Motion.content) {
                        selectedDay = nil
                        visibleWeek = thisWeek
                    }
                }
                .foregroundStyle(Theme.Colors.textSecondary)
            }
            Button { pageWeek(by: -1, now: now) } label: { Image(systemName: "chevron.left") }
                .foregroundStyle(Theme.Colors.textSecondary)
                .accessibilityLabel("Previous week")
            Button { pageWeek(by: 1, now: now) } label: { Image(systemName: "chevron.right") }
                .foregroundStyle(Theme.Colors.textSecondary)
                .accessibilityLabel("Next week")
        }
        .font(Theme.Text.micro)
        .buttonStyle(.plain)
    }

    private func pageWeek(by weeks: Int, now: Date) {
        let all = CalendarWeeks.weekStarts(around: now)
        let current = visibleWeek ?? CalendarWeeks.startOfWeek(for: now)
        guard let index = all.firstIndex(of: current) else { return }
        let target = min(max(index + weeks, 0), all.count - 1)
        withAnimation(Theme.Motion.content) { visibleWeek = all[target] }
    }

    // MARK: Day list

    @ViewBuilder
    private func dayList(_ events: [CalendarEvent], now: Date) -> some View {
        if events.isEmpty {
            HStack(spacing: 8) {
                Text(store.calendars.isEmpty
                    ? "No calendars yet. Add iCloud, Google or Microsoft in Internet Accounts."
                    : "Nothing scheduled.")
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
                if store.calendars.isEmpty {
                    Button("+ Add an account") { CalendarStore.openInternetAccounts() }
                        .buttonStyle(.notchSecondary())
                }
            }
        } else {
            // Column-major, so the day reads down the left column and continues on the right.
            let half = (events.count + 1) / 2
            let columns = HStack(alignment: .top, spacing: Theme.Metrics.CalendarPanel.listColumnSpacing) {
                column(Array(events.prefix(half)), now: now)
                column(Array(events.dropFirst(half)), now: now)
            }
            ViewThatFits(in: .vertical) {
                columns
                ScrollView { columns }.scrollIndicators(.never)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            // Each row pads its text inside its plate; pulling the list out by the same amount
            // puts the text on the column edge with the strip and the summary above it.
            .padding(.horizontal, -Theme.Metrics.CalendarPanel.rowHorizontalPadding)
        }
    }

    private func column(_ events: [CalendarEvent], now: Date) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.CalendarPanel.rowSpacing) {
            ForEach(events) { event in
                row(event, now: now)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func row(_ event: CalendarEvent, now: Date) -> some View {
        let isNext = event.id == store.nextEvent(at: now)?.id
        let isPast = event.end <= now

        return Button { store.open(event) } label: {
            HStack(spacing: 6) {
                Text(event.isAllDay ? "all-day" : event.start.formatted(date: .omitted, time: .shortened))
                    .font(Theme.Text.micro)
                    .monospacedDigit()
                    .foregroundStyle(isNext ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)
                    .lineLimit(1)
                    .frame(width: Theme.Metrics.CalendarPanel.timeColumnWidth, alignment: .leading)
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Self.color(event.color))
                    .frame(width: Theme.Metrics.CalendarPanel.colorMarkWidth, height: Theme.Metrics.CalendarPanel.colorMarkHeight)
                Text(event.title)
                    .font(Theme.Text.caption)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if event.meetingURL != nil {
                    if isNext {
                        Button("Join") { store.join(event) }
                            .buttonStyle(.notchPrimary(tint: Theme.Colors.textPrimary, size: .inline))
                            .help(event.meetingURL?.host ?? "")
                    } else if !isPast {
                        Image(systemName: "video")
                            .font(Theme.Text.micro)
                            .foregroundStyle(Theme.Colors.textTertiary)
                    }
                }
            }
            .padding(.horizontal, Theme.Metrics.CalendarPanel.rowHorizontalPadding)
            .frame(height: Theme.Metrics.CalendarPanel.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.CalendarPanel.rowCornerRadius, style: .continuous)
                    .fill(Theme.Colors.textPrimary.opacity(isNext ? Theme.Metrics.CalendarPanel.nextRowFillOpacity : 0))
            )
            .opacity(isPast ? Theme.Metrics.CalendarPanel.pastOpacity : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(CalendarRowStyle())
        .help("\(event.title) — \(Self.timeRange(event)) · \(event.calendarTitle)")
        .accessibilityLabel("\(event.title), \(Self.timeRange(event))")
    }

    // MARK: Access pitch

    private func pitch(headline: String, detail: String, action: String) -> some View {
        HStack(alignment: .center, spacing: Theme.Metrics.CalendarPanel.columnSpacing) {
            VStack(alignment: .leading, spacing: 8) {
                Text(headline).font(Theme.Text.title)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(Theme.Text.caption).foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action) { store.requestAccess() }
                    .buttonStyle(.notchSecondary())
                    .padding(.top, 2)
            }
            .frame(width: Theme.Metrics.CalendarPanel.detailWidth, alignment: .leading)
            Rectangle()
                .fill(Theme.Colors.textTertiary.opacity(Theme.Metrics.CalendarPanel.hairlineOpacity))
                .frame(width: 1)
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private static let providers = [
        "Apple iCloud & On My Mac",
        "Google Calendar",
        "Microsoft Outlook / Exchange",
        "Any CalDAV account",
    ]

    // MARK: Formatting

    /// The weekday, except on the 1st, which names its month — so paging into November says so.
    private static func cellLabel(_ day: Date) -> String {
        Calendar.current.component(.day, from: day) == 1
            ? day.formatted(.dateTime.month(.abbreviated))
            : day.formatted(.dateTime.weekday(.abbreviated))
    }

    private static func color(_ cgColor: CGColor?) -> Color {
        cgColor.map { Color(cgColor: $0) } ?? Theme.Colors.textTertiary
    }

    static func countdown(to event: CalendarEvent, now: Date) -> String {
        if event.isHappening(at: now) {
            return "Now · ends \(relative(event.end, from: now))"
        }
        return "Next \(relative(event.start, from: now))"
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

/// The solid Join chip on the next event's row — the one filled control in the panel.
/// Hover and press fill for an event row, matching the crypto watchlist's selected row.
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
                    RoundedRectangle(cornerRadius: Theme.Metrics.CalendarPanel.rowCornerRadius, style: .continuous)
                        .fill(Theme.Colors.textPrimary.opacity(configuration.isPressed ? 0.12 : hovered ? 0.06 : 0))
                )
                .onHover { hovered = $0 }
                .animation(Theme.Motion.content, value: hovered)
                .animation(Theme.Motion.content, value: configuration.isPressed)
        }
    }
}
