import CoreGraphics
import EventKit
import Foundation

enum CalendarSaveResult: Sendable {
    case saved(calendar: String)
    case failed(String)
}

/// Every EventKit call, on one serial queue. The store is made on first use and remade
/// after access changes; the rest of the feature only sees `CalendarEvent` values.
final class CalendarEventSource: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.dynamicnotch.calendar", qos: .utility)
    private var store: EKEventStore?     // only touched on `queue`

    static var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }

    /// Drops the store, so the next call sees access granted in System Settings.
    func reset() {
        queue.async { self.store = nil }
    }

    /// Asks for full access (macOS shows its prompt once) and says whether it was granted.
    func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                self.currentStore().requestFullAccessToEvents { granted, error in
                    if let error {
                        CalendarLog.logger.error("access request failed: \(error.localizedDescription, privacy: .public)")
                    }
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    /// Events overlapping `start..<end` in every calendar, sorted by start. Without
    /// `details`, skips the meeting-link search and attendees (for the month grid's dots).
    func events(from start: Date, to end: Date, details: Bool = true) async -> [CalendarEvent] {
        await withCheckedContinuation { continuation in
            queue.async {
                let store = self.currentStore()
                let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
                let events = store.events(matching: predicate)
                    .map { CalendarEvent(event: $0, details: details) }
                    .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
                continuation.resume(returning: events)
            }
        }
    }

    /// Saves a quick-add draft to the default calendar for new events.
    func save(_ draft: CalendarQuickAdd.Draft) async -> CalendarSaveResult {
        await withCheckedContinuation { continuation in
            queue.async {
                let store = self.currentStore()
                guard let calendar = store.defaultCalendarForNewEvents, calendar.allowsContentModifications else {
                    continuation.resume(returning: .failed("no calendar to add to"))
                    return
                }
                let event = EKEvent(eventStore: store)
                event.title = draft.title
                event.isAllDay = draft.isAllDay
                event.startDate = draft.start
                // EventKit keeps an all-day event's end on its last day.
                event.endDate = draft.isAllDay ? draft.end.addingTimeInterval(-1) : draft.end
                event.calendar = calendar
                do {
                    try store.save(event, span: .thisEvent, commit: true)
                    continuation.resume(returning: .saved(calendar: calendar.title))
                } catch {
                    CalendarLog.logger.error("save failed: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: .failed(error.localizedDescription))
                }
            }
        }
    }

    private func currentStore() -> EKEventStore {
        if let store { return store }
        let made = EKEventStore()
        store = made
        return made
    }
}

extension CalendarEvent {
    /// Copies what the notch shows out of an EventKit event. Runs on the source's queue.
    fileprivate init(event e: EKEvent, details: Bool) {
        let start: Date = e.startDate ?? Date.distantPast
        let end: Date = e.endDate ?? start
        let title = (e.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let location = (e.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let me = details ? e.attendees?.first(where: { $0.isCurrentUser }) : nil
        let uid: String? = e.calendarItemExternalIdentifier
        self.init(
            id: "\(e.eventIdentifier ?? e.calendarItemIdentifier)@\(Int(start.timeIntervalSince1970))",
            title: title.isEmpty ? "Untitled" : title,
            start: start,
            end: end,
            isAllDay: e.isAllDay,
            calendarTitle: e.calendar?.title ?? "",
            color: Self.color(e.calendar?.cgColor),
            location: location.isEmpty ? nil : location,
            link: details ? CalendarLinks.find(url: e.url, location: e.location, notes: e.hasNotes ? e.notes : nil) : nil,
            declined: me?.participantStatus == .declined,
            canceled: e.status == .canceled,
            uid: uid?.isEmpty == false ? uid : nil)
    }

    private static func color(_ cg: CGColor?) -> CalendarColor {
        guard let cg, let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let c = cg.converted(to: srgb, intent: .defaultIntent, options: nil),
              let parts = c.components, parts.count >= 3 else { return .fallback }
        return CalendarColor(red: Double(parts[0]), green: Double(parts[1]), blue: Double(parts[2]))
    }
}
