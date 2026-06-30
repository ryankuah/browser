import AppKit
import SwiftUI

struct BrowserCalendarPage: View {
    @ObservedObject var browser: BrowserState
    @ObservedObject var session: BrowserSessionController
    let onClose: () -> Void

    @State private var selectedEventID: BrowserCalendarEvent.ID?
    @State private var visibleMonth = Date()

    private var calendar: Calendar {
        Calendar.current
    }

    private var selectedEvent: BrowserCalendarEvent? {
        if let selectedEventID,
           let event = eventsForVisibleMonth.first(where: { $0.id == selectedEventID }) {
            return event
        }

        return nil
    }

    var body: some View {
        ZStack {
            BrowserChromeBackground(
                bezelStyle: browser.bezelStyle,
                cornerRadius: 0,
                effect: .liquidGlass(style: .regular, tintColor: NSColor.black.withAlphaComponent(0.16)),
                profileColor: browser.profileNSColor
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                Divider()
                    .opacity(0.45)

                if session.calendars.isEmpty && session.calendarEvents.isEmpty {
                    emptyState
                } else {
                    calendarContent
                }
            }
        }
        .onAppear {
            session.refreshCloudData()
        }
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Calendar")

            Image(systemName: "calendar")
                .font(.system(size: 15, weight: .semibold))

            Text("Calendar")
                .font(.system(size: 15, weight: .semibold))

            Text("\(session.calendarEvents.count)")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer()

            if session.hasConnectedGoogleAccount {
                Text(session.googleAccounts.first?.email ?? "Google connected")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Button {
                    session.openGoogleConnectionURL()
                } label: {
                    Label("Connect Google", systemImage: "link")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
            }

            Button {
                session.refreshCloudData()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("No Imported Events")
                .font(.system(size: 15, weight: .semibold))

            Text(emptyStateMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            if session.hasConnectedGoogleAccount {
                Button {
                    session.refreshCloudData()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    session.openGoogleConnectionURL()
                } label: {
                    Label("Connect Google", systemImage: "link")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateMessage: String {
        if let account = session.googleAccounts.first {
            return "Google is connected as \(account.email). Calendar data may still be importing, or no readable events were returned."
        }

        return "Connect Google to import Calendar data into Convex. Browser never writes events back to Google."
    }

    private var calendarContent: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                CalendarPickerList(session: session)

                Divider()
                    .opacity(0.45)

                CalendarMonthSidebar(
                    events: eventsForVisibleMonth,
                    selectedEventID: selectedEvent?.id,
                    onSelect: { selectedEventID = $0.id }
                )
            }
            .frame(width: 360)

            Divider()
                .opacity(0.45)

            VStack(spacing: 0) {
                monthToolbar

                Divider()
                    .opacity(0.45)

                CalendarMonthGrid(
                    month: visibleMonth,
                    events: eventsForVisibleMonth,
                    selectedEventID: selectedEvent?.id,
                    onSelect: { selectedEventID = $0.id }
                )
                .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var monthToolbar: some View {
        HStack(spacing: 10) {
            Button {
                shiftVisibleMonth(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Previous month")

            Text(visibleMonth, format: .dateTime.month(.wide).year())
                .font(.system(size: 18, weight: .semibold))

            Button {
                shiftVisibleMonth(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Next month")

            Spacer()

            Button("Today") {
                visibleMonth = Date()
                selectedEventID = nil
            }
            .buttonStyle(.bordered)
            .font(.system(size: 12, weight: .semibold))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var eventsForVisibleMonth: [BrowserCalendarEvent] {
        session.calendarEvents.filter { event in
            guard let date = event.startDate else {
                return false
            }

            return calendar.isDate(date, equalTo: visibleMonth, toGranularity: .month)
        }
    }

    private func shiftVisibleMonth(by value: Int) {
        visibleMonth = calendar.date(byAdding: .month, value: value, to: visibleMonth) ?? visibleMonth
        selectedEventID = nil
    }
}

private struct CalendarPickerList: View {
    @ObservedObject var session: BrowserSessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Imported Calendars")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            ForEach(session.calendars) { calendar in
                Toggle(isOn: Binding(
                    get: { calendar.selected },
                    set: { session.setCalendar(calendar, selected: $0) }
                )) {
                    Text(calendar.summary)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
                .toggleStyle(.checkbox)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CalendarEventRow: View {
    let event: BrowserCalendarEvent
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                VStack(spacing: 2) {
                    if let date = event.startDate {
                        Text(date, format: .dateTime.month(.abbreviated))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(date, format: .dateTime.day())
                            .font(.system(size: 17, weight: .semibold))
                    } else {
                        Text("--")
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                .frame(width: 38)

                VStack(alignment: .leading, spacing: 4) {
                    Text(event.summary ?? "Untitled event")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)

                    Text(event.location ?? event.startText ?? event.status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.primary.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct CalendarMonthSidebar: View {
    let events: [BrowserCalendarEvent]
    let selectedEventID: BrowserCalendarEvent.ID?
    let onSelect: (BrowserCalendarEvent) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if events.isEmpty {
                    Text("No events this month")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(events) { event in
                        CalendarEventRow(
                            event: event,
                            isSelected: selectedEventID == event.id
                        ) {
                            onSelect(event)
                        }
                        .contentShape(Rectangle())
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }
}

private struct CalendarMonthGrid: View {
    let month: Date
    let events: [BrowserCalendarEvent]
    let selectedEventID: BrowserCalendarEvent.ID?
    let onSelect: (BrowserCalendarEvent) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    private var calendar: Calendar { Calendar.current }
    private var weekdaySymbols: [String] { calendar.shortStandaloneWeekdaySymbols }

    var body: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(weekdaySymbols, id: \.self) { weekday in
                    Text(weekday)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }

            Divider()
                .opacity(0.45)

            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(monthDays) { day in
                    CalendarDayCell(
                        day: day,
                        events: eventsByDay[day.dayKey] ?? [],
                        selectedEventID: selectedEventID,
                        onSelect: onSelect
                    )
                    .frame(minHeight: 104)
                    .overlay(alignment: .topTrailing) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 1)
                    }
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var monthDays: [CalendarMonthDay] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let firstWeek = calendar.dateInterval(of: .weekOfMonth, for: interval.start) else {
            return []
        }

        var days: [CalendarMonthDay] = []
        var date = firstWeek.start
        while days.count < 42 {
            days.append(CalendarMonthDay(
                date: date,
                isInDisplayedMonth: calendar.isDate(date, equalTo: month, toGranularity: .month),
                isToday: calendar.isDateInToday(date),
                dayKey: calendar.startOfDay(for: date)
            ))
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return days
    }

    private var eventsByDay: [Date: [BrowserCalendarEvent]] {
        Dictionary(grouping: events) { event in
            event.startDate.map(calendar.startOfDay(for:)) ?? .distantPast
        }
    }
}

private struct CalendarMonthDay: Identifiable {
    let date: Date
    let isInDisplayedMonth: Bool
    let isToday: Bool
    let dayKey: Date

    var id: Date { dayKey }
}

private struct CalendarDayCell: View {
    let day: CalendarMonthDay
    let events: [BrowserCalendarEvent]
    let selectedEventID: BrowserCalendarEvent.ID?
    let onSelect: (BrowserCalendarEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(day.date, format: .dateTime.day())
                .font(.system(size: 12, weight: day.isToday ? .bold : .semibold))
                .foregroundStyle(day.isInDisplayedMonth ? Color.primary : Color.secondary.opacity(0.55))
                .frame(width: 24, height: 24)
                .background {
                    if day.isToday {
                        Circle()
                            .fill(Color.accentColor.opacity(0.24))
                    }
                }

            ForEach(events.prefix(4)) { event in
                Button {
                    onSelect(event)
                } label: {
                    Text(event.summary ?? "Untitled event")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(selectedEventID == event.id ? Color.accentColor.opacity(0.26) : Color.primary.opacity(0.08))
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if events.count > 4 {
                Text("+\(events.count - 4) more")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(day.isInDisplayedMonth ? Color.clear : Color.primary.opacity(0.025))
    }
}

private struct CalendarEventDetail: View {
    let event: BrowserCalendarEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(event.summary ?? "Untitled event")
                .font(.system(size: 22, weight: .semibold))
                .textSelection(.enabled)

            Divider()
                .opacity(0.45)

            detailLine("Status", event.status)
            detailLine("Starts", event.startText)
            detailLine("Ends", event.endText)
            detailLine("Location", event.location)

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func detailLine(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value ?? "-")
                .font(.system(size: 13))
                .textSelection(.enabled)
        }
    }
}
