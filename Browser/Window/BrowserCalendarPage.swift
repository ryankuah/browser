import AppKit
import SwiftUI

struct BrowserCalendarPage: View {
    @ObservedObject var browser: BrowserState
    @ObservedObject var session: BrowserSessionController
    let onClose: () -> Void

    @State private var selectedEventID: BrowserCalendarEvent.ID?

    private var selectedEvent: BrowserCalendarEvent? {
        if let selectedEventID,
           let event = session.calendarEvents.first(where: { $0.id == selectedEventID }) {
            return event
        }

        return session.calendarEvents.first
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

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(session.calendarEvents) { event in
                            CalendarEventRow(
                                event: event,
                                isSelected: selectedEvent?.id == event.id
                            ) {
                                selectedEventID = event.id
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .frame(width: 360)

            Divider()
                .opacity(0.45)

            if let selectedEvent {
                CalendarEventDetail(event: selectedEvent)
            } else {
                Text("Select an event")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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
        }
        .buttonStyle(.plain)
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
