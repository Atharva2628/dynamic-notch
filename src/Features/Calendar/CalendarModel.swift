import Foundation
import SwiftUI

/// What the views can ask for. The feature fills these in; snapshots leave them empty.
struct CalendarActions {
    var requestAccess: @MainActor () -> Void = {}
    var enable: @MainActor () -> Void = {}
    var openPrivacySettings: @MainActor () -> Void = {}
    var openTab: @MainActor () -> Void = {}
    var close: @MainActor () -> Void = {}
    var loadMonth: @MainActor (Date) -> Void = { _ in }
    var browse: @MainActor (Date) -> Void = { _ in }
    var save: @MainActor (CalendarQuickAdd.Draft) -> Void = { _ in }
    /// A click on quick add: the panel takes the keyboard and the field gets focus.
    var startTyping: @MainActor () -> Void = {}
    /// Opens the event's meeting link; also dismisses its alert.
    var join: @MainActor (CalendarEvent) -> Void = { _ in }
    /// Shows or hides one calendar's events everywhere (agenda, Home, alerts).
    var toggleCalendar: @MainActor (String) -> Void = { _ in }
    /// Reads the calendar list for the picker.
    var loadCalendars: @MainActor () -> Void = {}
}

/// The calendar's state as the tab and the Home card show it. The feature fills it from
/// EventKit; snapshots fill it with samples.
@MainActor
final class CalendarModel: ObservableObject {
    enum Access: Equatable {
        case off              // calendarEnabled is false
        case notDetermined    // macOS hasn't asked yet, or the prompt is up
        case denied           // denied, restricted or write-only
        case granted
    }

    @Published var access: Access
    /// The clock the views use; the feature moves it on every minute.
    @Published var now: Date
    @Published var upcoming: [CalendarEvent] = []      // today through `days` ahead
    @Published var loaded = false
    /// When set, the agenda starts on this day instead of today (picked in the month grid).
    @Published var browseStart: Date?
    @Published var browseEvents: [CalendarEvent]?      // nil while loading
    @Published var month: Date                         // first day of the month the grid shows
    @Published var busyDays: Set<Date> = []
    @Published var selectedDay: Date?
    @Published var scrollTarget: Date?
    @Published var draftText = "" {
        // Typing brings the draft preview back over a message; a save clearing the text doesn't.
        didSet { if draftText != oldValue && !draftText.isEmpty { message = nil } }
    }
    @Published var message: String?
    @Published var focusRequest = 0
    /// Quick add has the keyboard: from a click on it until the tab goes away or a save
    /// empties it. Until then the field is a placeholder you click.
    @Published var typing = false
    /// A quick-add save is in flight; Return does nothing until it's done.
    @Published var saving = false
    /// The month grid's place shows the list of calendars, each with a switch.
    @Published var choosingCalendars = false
    @Published var calendars: [CalendarChoice] = []
    /// From `hiddenCalendars`; the feature keeps it in step with the settings.
    @Published var hiddenCalendars: Set<String> = []

    /// Days the agenda covers: today plus `calendarDays`.
    var days = 8
    var calendar: Calendar
    /// Swaps views that can't render offscreen (text field, scroll view) for plain ones.
    var isSnapshot = false
    var actions = CalendarActions()

    init(access: Access, now: Date, calendar: Calendar = .autoupdatingCurrent) {
        self.access = access
        self.now = now
        self.calendar = calendar
        self.month = CalendarMonthLayout.monthStart(now, calendar: calendar)
    }

    var today: Date { calendar.startOfDay(for: now) }
    var agendaStart: Date { browseStart ?? today }

    var sections: [CalendarAgenda.Day] {
        let events = browseStart == nil ? upcoming : (browseEvents ?? [])
        var keep: Set<Date> = [today]
        if let selectedDay { keep.insert(selectedDay) }
        return CalendarAgenda.group(events, from: agendaStart, days: days, now: now, keep: keep, calendar: calendar)
    }

    /// The next timed event that hasn't ended (it may be under way), and the one after it.
    /// With no timed events left, the next all-day one. A meeting in two calendars counts
    /// once, so "Then" never repeats it.
    var nextEvents: (next: CalendarEvent?, then: CalendarEvent?) {
        let events = CalendarAlerts.merged(upcoming)
        let timed = events.filter { $0.isAttendable && $0.end > now }.sorted { $0.start < $1.start }
        if let first = timed.first { return (first, timed.dropFirst().first) }
        let allDay = events.filter { $0.isAllDay && !$0.declined && !$0.canceled && $0.end > now }
        return (allDay.min { $0.start < $1.start }, nil)
    }

    /// Earlier, Now and Next for the Home card and the agenda's markers.
    var timeline: CalendarTimeline.Rows { CalendarTimeline.rows(upcoming, now: now, calendar: calendar) }

    var draft: CalendarQuickAdd.Draft? {
        CalendarQuickAdd.parse(draftText, now: now, calendar: calendar)
    }

    /// Picks a day in the month grid: scrolls to it when the agenda covers it, otherwise
    /// starts the agenda there.
    func pick(_ day: Date) {
        let day = calendar.startOfDay(for: day)
        selectedDay = day
        let dayMonth = CalendarMonthLayout.monthStart(day, calendar: calendar)
        if dayMonth != month { showMonth(dayMonth) }
        if contains(day, from: agendaStart) {
            // already listed
        } else if contains(day, from: today) {
            browseStart = nil
            browseEvents = nil
        } else {
            browseStart = day
            browseEvents = nil
            actions.browse(day)
        }
        scrollTarget = day
    }

    func moveMonth(_ delta: Int) {
        if let m = calendar.date(byAdding: .month, value: delta, to: month) { showMonth(m) }
    }

    func goToday() {
        selectedDay = nil
        browseStart = nil
        browseEvents = nil
        showMonth(CalendarMonthLayout.monthStart(now, calendar: calendar))
        scrollTarget = today
    }

    var isAtToday: Bool {
        selectedDay == nil && browseStart == nil && month == CalendarMonthLayout.monthStart(now, calendar: calendar)
    }

    /// Return in the quick-add field. Without a day or time the preview already says so.
    /// While a save is in flight, another Return (or a held one) adds nothing.
    func submit() {
        guard !saving, let draft else { return }
        actions.save(draft)
    }

    /// Esc clears the quick-add text first, then closes the notch.
    func escape() {
        if draftText.isEmpty { actions.close() } else { draftText = "" }
    }

    func tabAppeared() {
        actions.loadMonth(month)
    }

    func toggleChoosingCalendars() {
        choosingCalendars.toggle()
        if choosingCalendars && calendars.isEmpty { actions.loadCalendars() }
    }

    /// Calendars hidden that still exist; a deleted calendar's id stays in the settings harmlessly.
    var hiddenCount: Int { calendars.filter { hiddenCalendars.contains($0.id) }.count }

    private func showMonth(_ m: Date) {
        month = m
        actions.loadMonth(m)
    }

    private func contains(_ day: Date, from start: Date) -> Bool {
        guard let end = calendar.date(byAdding: .day, value: days, to: start) else { return false }
        return day >= start && day < end
    }
}
