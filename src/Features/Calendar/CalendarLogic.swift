import Foundation
import os

enum CalendarLog {
    static let logger = Logger(subsystem: "local.dynamicnotch", category: "calendar")
}

/// A calendar's color in sRGB, copied out of EventKit so it can cross threads.
struct CalendarColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static let fallback = CalendarColor(red: 0.55, green: 0.6, blue: 0.7)
}

/// One occurrence of an event, as plain values. A recurring event has one per occurrence;
/// `id` tells them apart by start time.
struct CalendarEvent: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay = false
    var calendarTitle = ""
    var color = CalendarColor.fallback
    var location: String? = nil
    var link: CalendarMeetingLink? = nil
    var declined = false
    var canceled = false
    /// The invitation's iCalendar UID, the same in every calendar the meeting is in. Nil
    /// when EventKit has none.
    var uid: String? = nil

    /// The meeting across calendars: its UID and start, else `id`. Alerts and dismissals use
    /// it, so a meeting in two calendars alerts once, and a dismissal survives the server
    /// changing `eventIdentifier`.
    var key: String { uid.map { "\($0)@\(Int(start.timeIntervalSince1970))" } ?? id }

    /// Timed, not declined and not canceled: the events that get a meeting alert and count
    /// as "next" on the Home card.
    var isAttendable: Bool { !isAllDay && !declined && !canceled }

    /// The meeting service, or else the first line of the location.
    var place: String? {
        if let link { return link.service.name }
        let line = location?.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        return line?.isEmpty == false ? line : nil
    }
}

/// One calendar in the Calendar app, for the list that picks which ones show.
struct CalendarChoice: Identifiable, Equatable, Sendable {
    var id: String          // EKCalendar.calendarIdentifier, what `hiddenCalendars` stores
    var title: String
    var account: String     // iCloud, Google, Subscribed Calendars, Other…
    var color = CalendarColor.fallback
}

enum CalendarChoices {
    struct Group: Equatable {
        var account: String
        var calendars: [CalendarChoice]
    }

    /// By account, in the order the accounts first appear, each sorted by title.
    static func grouped(_ calendars: [CalendarChoice]) -> [Group] {
        var order: [String] = []
        var byAccount: [String: [CalendarChoice]] = [:]
        for c in calendars {
            if byAccount[c.account] == nil { order.append(c.account) }
            byAccount[c.account, default: []].append(c)
        }
        return order.map { account in
            Group(account: account, calendars: byAccount[account, default: []].sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            })
        }
    }
}

// MARK: - Meeting links

enum CalendarMeetingService: String, Sendable {
    case zoom, meet, teams, webex

    var name: String {
        switch self {
        case .zoom: "Zoom"
        case .meet: "Google Meet"
        case .teams: "Teams"
        case .webex: "Webex"
        }
    }

    /// The service whose join link `url` is, or nil for any other link (help pages, the
    /// services' own home pages).
    static func of(_ url: URL) -> CalendarMeetingService? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return nil }
        let path = url.path(percentEncoded: false).lowercased()
        func within(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }

        if within("zoom.us") || within("zoomgov.com") {
            return ["/j/", "/my/", "/w/", "/s/"].contains { path.hasPrefix($0) } ? .zoom : nil
        }
        if host == "meet.google.com" {
            return path.count > 1 && !path.hasPrefix("/_meet") ? .meet : nil
        }
        if host == "teams.microsoft.com" {
            return path.hasPrefix("/l/meetup-join/") || path.hasPrefix("/meet/") ? .teams : nil
        }
        if host == "teams.live.com" {
            return path.hasPrefix("/meet/") ? .teams : nil
        }
        if within("webex.com") {
            // Join links live on a company subdomain: acme.webex.com/meet/ana, …/j.php?MTID=…
            let sub = host.dropLast("webex.com".count)
            return !sub.isEmpty && !["www.", "help."].contains(String(sub)) && path.count > 1 ? .webex : nil
        }
        return nil
    }
}

struct CalendarMeetingLink: Equatable, Sendable {
    var url: URL
    var service: CalendarMeetingService
}

/// Finds the join link of a Zoom, Meet, Teams or Webex meeting in an event.
enum CalendarLinks {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Looks in the event's URL first, then its location, then its notes.
    static func find(url: URL?, location: String?, notes: String?) -> CalendarMeetingLink? {
        if let url, let link = link(url) { return link }
        for text in [location, notes] {
            if let text, let link = first(in: text) { return link }
        }
        return nil
    }

    /// The first meeting link in free text. Links without a scheme count
    /// ("meet.google.com/abc-defg-hij").
    static func first(in text: String) -> CalendarMeetingLink? {
        guard let detector, !text.isEmpty else { return nil }
        let ns = text as NSString
        let range = NSRange(location: 0, length: min(ns.length, 20_000))   // long HTML notes
        for match in detector.matches(in: text, options: [], range: range) {
            if let url = match.url, let link = link(url) { return link }
        }
        return nil
    }

    /// A meeting link for `url`, upgraded to https (every service supports it).
    static func link(_ url: URL) -> CalendarMeetingLink? {
        guard let service = CalendarMeetingService.of(url) else { return nil }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.scheme = "https"
        return CalendarMeetingLink(url: parts?.url ?? url, service: service)
    }
}

// MARK: - Quick add

/// Turns "lunch fri 1pm" into an event: NSDataDetector finds the date, the rest is the title.
/// Events last an hour unless the text says otherwise ("2-3pm", "for 30 min"); a day
/// without a time makes an all-day event.
enum CalendarQuickAdd {
    struct Draft: Equatable, Sendable {
        var title: String
        var start: Date
        var end: Date              // exclusive; for all-day events, midnight after the last day
        var isAllDay: Bool
    }

    /// A date the detector found: where it is in the text, the date it means, and how long
    /// it lasts when the text gives a range.
    struct Match: Equatable {
        var range: NSRange
        var date: Date
        var duration: TimeInterval = 0
    }

    static let defaultLength: TimeInterval = 3600
    static let untitled = "New Event"

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    private static let lengthPattern = try? NSRegularExpression(
        pattern: #"\bfor\s+(\d+(?:[.,]\d+)?)\s*(hours?|hrs?|h|minutes?|mins?|m)\b"#, options: [.caseInsensitive])
    /// Times the detector reads at 12:00, where the noon check in `draft` can't tell them from
    /// a day alone ("at 12", "12 o'clock", "lunch").
    private static let timePattern = try? NSRegularExpression(
        pattern: #"\d\s*[ap]\.?m\b|\d{1,2}:\d{2}|\d{1,2}h\d{2}|(?:\bat|@)\s*\d{1,2}\b|o'?clock|\b(noon|midnight|tonight|morning|afternoon|evening|night|breakfast|brunch|lunch|lunchtime|dinner|supper)\b"#,
        options: [.caseInsensitive])
    private static let yearPattern = try? NSRegularExpression(pattern: #"\b(?:19|20)\d{2}\b"#)
    private static let numericDatePattern = try? NSRegularExpression(pattern: #"\b\d{1,2}[/.]\d{1,2}\b|\b\d{4}-\d{2}-\d{2}\b"#)

    /// Meal words the detector reads as times ("lunch" is noon). They stay in the title too.
    private static let meals: Set<String> = ["breakfast", "brunch", "lunch", "lunchtime", "dinner", "supper"]
    /// Words left dangling where the date was cut out ("Lunch with Sam on").
    private static let connectors: Set<String> = ["at", "on", "from", "by", "@"]
    private static let weekdays: Set<String> = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
                                                "sun", "mon", "tue", "tues", "wed", "weds", "thu", "thur", "thurs", "fri", "sat"]
    private static let months: Set<String> = ["january", "february", "march", "april", "may", "june", "july", "august",
                                              "september", "october", "november", "december", "jan", "feb", "mar", "apr",
                                              "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec"]
    private static let dayWords: Set<String> = ["today", "tonight", "tomorrow", "tmrw", "tmr"]

    /// Nil when the text names no day or time.
    static func parse(_ text: String, now: Date, calendar: Calendar) -> Draft? {
        let (cleaned, length) = extractLength(text)
        guard let detector, !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let ns = cleaned as NSString
        guard let found = detector.firstMatch(in: cleaned, options: [], range: NSRange(location: 0, length: ns.length)),
              let date = found.date else { return nil }
        return draft(cleaned, match: Match(range: found.range, date: date, duration: found.duration),
                     length: length, now: now, calendar: calendar)
    }

    /// Takes "for 30 min" / "for 2h" out of the text (blanked, so offsets stay put) and
    /// returns its length in seconds.
    static func extractLength(_ text: String) -> (text: String, length: TimeInterval?) {
        let ns = text as NSString
        guard let lengthPattern,
              let m = lengthPattern.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)),
              let amount = Double(ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: ".")),
              amount > 0 else { return (text, nil) }
        let unit = ns.substring(with: m.range(at: 2)).lowercased()
        let seconds = amount * (unit.hasPrefix("h") ? 3600 : 60)
        let blank = String(repeating: " ", count: m.range.length)
        return (ns.replacingCharacters(in: m.range, with: blank), min(seconds, 7 * 86_400))
    }

    /// Builds the event from a detector match. Pure: `now` and `calendar` decide everything,
    /// so it can be checked against a fixed date.
    static func draft(_ text: String, match: Match, length: TimeInterval?, now: Date, calendar: Calendar) -> Draft {
        let ns = text as NSString
        let phrase = ns.substring(with: match.range)
        let words = phrase.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        // The detector puts a day without a time at exactly 12:00, and keeps any time it read
        // ("tomorrow at 6" is 18:00), so anything else is timed even when the words don't say so.
        let clock = calendar.dateComponents([.hour, .minute, .second], from: match.date)
        let dayOnly = clock.hour == 12 && clock.minute == 0 && clock.second == 0
        let timed = matches(timePattern, phrase) || !dayOnly

        var start = timed ? match.date : calendar.startOfDay(for: match.date)
        start = rollForward(start, timed: timed, words: words, phrase: phrase, now: now, calendar: calendar)

        let end: Date
        if timed {
            end = start.addingTimeInterval(length ?? (match.duration > 0 ? match.duration : defaultLength))
        } else {
            // "nov 5 - nov 8" comes back as noon on the 5th plus three days.
            let first = calendar.startOfDay(for: match.date)
            let last = calendar.startOfDay(for: match.date.addingTimeInterval(max(0, match.duration)))
            let extra = calendar.dateComponents([.day], from: first, to: last).day ?? 0
            end = calendar.date(byAdding: .day, value: extra + 1, to: start) ?? start.addingTimeInterval(86_400)
        }

        // "Lunch with Sam on [Friday at 1pm]" → "Lunch with Sam"; "[fri 1pm] at Tartine" →
        // "Tartine"; but "Lunch [fri 1pm] at Tartine" keeps its "at".
        let kept = phrase.split(whereSeparator: \.isWhitespace).map(String.init)
            .filter { meals.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) }
        let before = trimConnectors(ns.substring(to: match.range.location), fromEnd: true)
        var after = ns.substring(from: NSMaxRange(match.range))
        if before.isEmpty && kept.isEmpty { after = trimConnectors(after, fromEnd: false) }
        let title = trimConnectors([before, kept.joined(separator: " "), after].joined(separator: " "), fromEnd: true)
        return Draft(title: title.isEmpty ? untitled : title, start: start, end: end, isAllDay: !timed)
    }

    /// The detector sometimes lands in the past: "3pm" after 3pm, "fri" late on a Friday,
    /// "oct 1" in late October. Those mean the next one.
    private static func rollForward(_ start: Date, timed: Bool, words: [String], phrase: String,
                                    now: Date, calendar: Calendar) -> Date {
        let threshold = timed ? now : calendar.startOfDay(for: now)
        guard start < threshold, !matches(yearPattern, phrase) else { return start }
        let saysDay = words.contains { dayWords.contains($0) }
        let saysWeekday = words.contains { weekdays.contains($0) }
        let saysDate = words.contains { months.contains($0) } || matches(numericDatePattern, phrase)
        let earlierDay = calendar.startOfDay(for: start) < calendar.startOfDay(for: now)

        if saysWeekday && !saysDate {
            return calendar.date(byAdding: .day, value: 7, to: start) ?? start
        }
        if !saysDay && !saysDate && timed && !earlierDay {
            return calendar.date(byAdding: .day, value: 1, to: start) ?? start
        }
        if saysDate && earlierDay {
            return calendar.date(byAdding: .year, value: 1, to: start) ?? start
        }
        return start
    }

    private static func trimConnectors(_ text: String, fromEnd: Bool) -> String {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let punctuation = CharacterSet(charactersIn: ",;:-–—")
        while let word = fromEnd ? words.last : words.first {
            let bare = word.trimmingCharacters(in: punctuation)
            if bare.isEmpty || connectors.contains(bare.lowercased()) {
                if fromEnd { words.removeLast() } else { words.removeFirst() }
            } else {
                if fromEnd { words[words.count - 1] = word.trimmingCharacters(in: punctuation) }
                else { words[0] = word.trimmingCharacters(in: punctuation) }
                break
            }
        }
        return words.joined(separator: " ")
    }

    private static func matches(_ pattern: NSRegularExpression?, _ text: String) -> Bool {
        guard let pattern else { return false }
        return pattern.firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }
}

// MARK: - Meeting alerts

enum CalendarAlerts {
    static let prefix = "calendar.meeting."
    /// Alerts stay up this long after the start, then go.
    static let linger: TimeInterval = 5 * 60

    static func activityID(_ event: CalendarEvent) -> String { prefix + event.key }

    /// From `leadMinutes` before a timed event until 5 minutes after it starts, unless it
    /// was dismissed or declined. A lead of 0 turns alerts off. `dismissed` holds keys.
    static func isDue(_ event: CalendarEvent, now: Date, leadMinutes: Int, dismissed: Set<String>) -> Bool {
        guard leadMinutes > 0, event.isAttendable, !dismissed.contains(event.key) else { return false }
        let opens = event.start.addingTimeInterval(-Double(leadMinutes) * 60)
        return now >= opens && now < event.start.addingTimeInterval(linger)
    }

    /// Run it on `merged` events, so a meeting in two calendars alerts once.
    static func due(_ events: [CalendarEvent], now: Date, leadMinutes: Int, dismissed: Set<String>) -> [CalendarEvent] {
        events.filter { isDue($0, now: now, leadMinutes: leadMinutes, dismissed: dismissed) }
    }

    /// The next moment an alert opens or a shown one's countdown changes ("3 min" to "2 min",
    /// "1 min" to "Now"), so the feature can wake up then instead of on its 30 s tick. Nil
    /// when nothing is coming.
    static func nextChange(_ events: [CalendarEvent], now: Date, leadMinutes: Int, dismissed: Set<String>) -> Date? {
        guard leadMinutes > 0 else { return nil }
        var next: Date?
        for event in events where event.isAttendable && !dismissed.contains(event.key) {
            let opens = event.start.addingTimeInterval(-Double(leadMinutes) * 60)
            let change: Date
            if opens > now {
                change = opens
            } else if event.start > now {
                // Showing "k min" until the time left reaches (k - 1) minutes.
                let minutes = (event.start.timeIntervalSince(now) / 60).rounded(.up)
                change = event.start.addingTimeInterval(-(minutes - 1) * 60)
            } else {
                continue
            }
            if change > now && change < (next ?? .distantFuture) { next = change }
        }
        return next
    }

    /// Copies of one meeting: the same invitation in two calendars (the same key), or an
    /// Exchange delegate's copy, whose UID differs (the same title and start).
    static func sameMeeting(_ a: CalendarEvent, _ b: CalendarEvent) -> Bool {
        a.key == b.key || (a.title == b.title && a.start == b.start)
    }

    /// One copy of each timed meeting, for alerts and the Home card; the agenda lists every
    /// copy, as Calendar does. A meeting declined or canceled in any copy is left out, and
    /// the copy with a join link is kept. All-day events pass through, first.
    static func merged(_ events: [CalendarEvent]) -> [CalendarEvent] {
        var groups: [[CalendarEvent]] = []
        var byKey: [String: Int] = [:]
        var byTime: [String: Int] = [:]        // "start title"
        for event in events where !event.isAllDay {
            let time = "\(event.start.timeIntervalSince1970) \(event.title)"
            let i = byKey[event.key] ?? byTime[time] ?? groups.count
            if i == groups.count { groups.append([]) }
            groups[i].append(event)
            if byKey[event.key] == nil { byKey[event.key] = i }
            if byTime[time] == nil { byTime[time] = i }
        }
        let meetings = groups.compactMap { copies -> CalendarEvent? in
            guard !copies.contains(where: { $0.declined || $0.canceled }) else { return nil }
            // The same copy on every reload, so its alert keeps its id.
            return copies.min { ($0.link == nil ? 1 : 0, $0.key, $0.id) < ($1.link == nil ? 1 : 0, $1.key, $1.id) }
        }
        return events.filter(\.isAllDay) + meetings
    }

    /// "5 min" counting down to "1 min", then "Now".
    static func countdown(to start: Date, now: Date) -> String {
        let seconds = start.timeIntervalSince(now)
        guard seconds > 0 else { return "Now" }
        return "\(Int((seconds / 60).rounded(.up))) min"
    }

    /// The compact-view activity for a meeting about to start. Join appears only with a link.
    /// Its duration ends it right at start + 5 min, between the 30 s checks.
    static func activity(_ event: CalendarEvent, now: Date) -> Activity {
        var actions: [ActivityAction] = []
        if event.link != nil { actions.append(ActivityAction(id: "join", title: "Join", style: .primary)) }
        actions.append(ActivityAction(id: "dismiss", title: "Dismiss"))
        let subtitle = [CalendarFormat.timeRange(event), event.place].compactMap { $0 }.joined(separator: " · ")
        return Activity(id: activityID(event), priority: .alert,
                        symbol: event.link == nil ? "calendar" : "video.fill", tint: .red,
                        accessory: .text(countdown(to: event.start, now: now)),
                        title: event.title, subtitle: subtitle,
                        duration: max(1, event.start.addingTimeInterval(linger).timeIntervalSince(now)),
                        urgent: true, actions: actions, opensTab: .calendar)
    }
}

// MARK: - Agenda

enum CalendarAgenda {
    struct Day: Identifiable, Equatable {
        var date: Date                 // start of the day
        var events: [CalendarEvent]
        var id: Date { date }
    }

    /// One section per day for `days` days from `start`. Events spanning several days show
    /// on each; all-day events come first, then by start time. Of the events that already
    /// ended today, only the last one stays (the agenda's "Earlier"). Empty days are skipped,
    /// except the ones in `keep`.
    static func group(_ events: [CalendarEvent], from start: Date, days: Int, now: Date,
                      keep: Set<Date>, calendar: Calendar) -> [Day] {
        let first = calendar.startOfDay(for: start)
        let today = calendar.startOfDay(for: now)
        let lastEnded = CalendarTimeline.rows(events, now: now, calendar: calendar).previous
        var result: [Day] = []
        for offset in 0..<max(days, 0) {
            guard let dayStart = calendar.date(byAdding: .day, value: offset, to: first),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            let isToday = dayStart == today
            let list = events
                .filter { overlaps($0, dayStart, dayEnd)
                    && (!(isToday && !$0.isAllDay && $0.end <= now) || $0.id == lastEnded?.id) }
                .sorted { a, b in
                    if a.isAllDay != b.isAllDay { return a.isAllDay }
                    return a.start != b.start ? a.start < b.start : a.title < b.title
                }
            if !list.isEmpty || keep.contains(dayStart) {
                result.append(Day(date: dayStart, events: list))
            }
        }
        return result
    }

    /// Days in `from..<to` that have at least one event (for the month grid's dots).
    static func busyDays(_ events: [CalendarEvent], from: Date, to: Date, calendar: Calendar) -> Set<Date> {
        var days = Set<Date>()
        for event in events where !event.canceled {
            var day = max(calendar.startOfDay(for: event.start), calendar.startOfDay(for: from))
            while day < to, let next = calendar.date(byAdding: .day, value: 1, to: day) {
                if overlaps(event, day, next) { days.insert(day) } else if day > event.end { break }
                day = next
            }
        }
        return days
    }

    static func overlaps(_ event: CalendarEvent, _ dayStart: Date, _ dayEnd: Date) -> Bool {
        if event.end <= event.start { return event.start >= dayStart && event.start < dayEnd }
        return event.start < dayEnd && event.end > dayStart
    }
}

// MARK: - Month grid

enum CalendarMonthLayout {
    static func monthStart(_ date: Date, calendar: Calendar) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? calendar.startOfDay(for: date)
    }

    /// The 42 days (6 weeks) a month grid shows, starting on the locale's first weekday.
    static func days(month: Date, calendar: Calendar) -> [Date] {
        let first = monthStart(month, calendar: calendar)
        let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -lead, to: first) else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }

    /// Very short weekday names in grid order ("S M T W T F S").
    static func weekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard !symbols.isEmpty else { return [] }
        let shift = ((calendar.firstWeekday - 1) % symbols.count + symbols.count) % symbols.count
        return Array(symbols[shift...] + symbols[..<shift])
    }
}

// MARK: - Text

/// The three moments the Home card and the agenda mark: the last event that ended today,
/// what's on now, and what's next. Timed events that aren't declined or canceled; a
/// meeting in two calendars counts once.
enum CalendarTimeline {
    struct Rows: Equatable {
        var previous: CalendarEvent?
        var current: CalendarEvent?      // a timed event under way, else today's all-day event
        var next: CalendarEvent?
    }

    static func rows(_ events: [CalendarEvent], now: Date, calendar: Calendar) -> Rows {
        let merged = CalendarAlerts.merged(events)
        let timed = merged.filter(\.isAttendable)
        let today = calendar.startOfDay(for: now)
        let previous = timed.filter { $0.end <= now && $0.end > today }.max { $0.end < $1.end }
        // Of overlapping events, the one that started last is the one you're in.
        let current = timed.filter { $0.start <= now && $0.end > now }.max { $0.start < $1.start }
            ?? merged.filter { $0.isAllDay && !$0.declined && !$0.canceled && $0.start <= now && $0.end > now }
                .min { $0.title < $1.title }
        let next = timed.filter { $0.start > now }.min { $0.start < $1.start }
        return Rows(previous: previous, current: current, next: next)
    }

    /// "ended 10 min ago", or "ended at 9:30" after an hour.
    static func ended(_ event: CalendarEvent, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(event.end) / 60)
        if minutes < 1 { return "just ended" }
        if minutes < 60 { return "ended \(minutes) min ago" }
        return "ended at \(CalendarFormat.time(event.end))"
    }

    /// What the Now row says with nothing on: free until the next event today, or for the day.
    static func free(next: CalendarEvent?, now: Date, calendar: Calendar) -> String {
        guard let next, calendar.isDate(next.start, inSameDayAs: now) else { return "for the rest of the day" }
        return "until \(CalendarFormat.time(next.start))"
    }
}

enum CalendarFormat {
    /// "in 25 min", "in 2 h 5 min", "Now", "Tomorrow", "Wednesday", or "Nov 12" a week or more
    /// out (with `calendarDays` above 6); "Today" for an all-day event.
    static func until(_ event: CalendarEvent, now: Date, calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: event.start)
        if event.isAllDay {
            if day <= today { return "Today" }
        } else {
            if event.start <= now { return event.end > now ? "Now" : "Ended" }
            let minutes = Int((event.start.timeIntervalSince(now) / 60).rounded(.up))
            if minutes < 60 { return "in \(minutes) min" }
            if day == today || minutes < 6 * 60 {
                let h = minutes / 60, m = minutes % 60
                return m == 0 ? "in \(h) h" : "in \(h) h \(m) min"
            }
        }
        if day == calendar.date(byAdding: .day, value: 1, to: today) { return "Tomorrow" }
        var style = Date.FormatStyle(locale: calendar.locale ?? .autoupdatingCurrent, calendar: calendar,
                                     timeZone: calendar.timeZone)
        if let weekOut = calendar.date(byAdding: .day, value: 7, to: today), day >= weekOut {
            // A weekday name alone would be ambiguous.
            style = style.month(.abbreviated).day()
        } else {
            style = style.weekday(.wide)
        }
        return event.start.formatted(style)
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "12:30" today, "Tue 9:30" on another day.
    static func shortStart(_ event: CalendarEvent, now: Date, calendar: Calendar) -> String {
        let day = calendar.isDate(event.start, inSameDayAs: now) ? nil : event.start.formatted(.dateTime.weekday(.abbreviated))
        let time = event.isAllDay ? nil : time(event.start)
        return [day, time].compactMap { $0 }.joined(separator: " ")
    }

    /// "10:30 – 11:00", or "All day".
    static func timeRange(_ event: CalendarEvent) -> String {
        guard !event.isAllDay else { return "All day" }
        guard event.end > event.start else { return time(event.start) }
        return (event.start..<event.end).formatted(.interval.hour().minute())
    }

    /// The agenda's time column for `event` on `day`: start over end, "All day", or how a
    /// multi-day event continues ("…" over its end time).
    static func rowTimes(_ event: CalendarEvent, day: Date, calendar: Calendar) -> (top: String, bottom: String?) {
        if event.isAllDay { return ("All day", nil) }
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        let startsToday = event.start >= day
        let endsToday = event.end <= dayEnd
        switch (startsToday, endsToday) {
        case (true, true): return (time(event.start), event.end > event.start ? time(event.end) : nil)
        case (true, false): return (time(event.start), "→")
        case (false, true): return ("…", time(event.end))
        case (false, false): return ("All day", nil)
        }
    }

    /// "Today", "Tomorrow", or "Wed, Oct 28".
    static func dayTitle(_ day: Date, now: Date, calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: now)
        if day == today { return "Today" }
        if day == calendar.date(byAdding: .day, value: 1, to: today) { return "Tomorrow" }
        if day == calendar.date(byAdding: .day, value: -1, to: today) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    /// "Fri, Oct 30 · 13:00 – 14:00", "Thu, Dec 24 · All day", "Nov 5 – 8 · All day".
    static func draftSummary(_ draft: CalendarQuickAdd.Draft, calendar: Calendar) -> String {
        let day = draft.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        if draft.isAllDay {
            let last = calendar.date(byAdding: .day, value: -1, to: draft.end) ?? draft.start
            if last > draft.start {
                return (draft.start..<last).formatted(.interval.month(.abbreviated).day()) + " · All day"
            }
            return day + " · All day"
        }
        return day + " · " + (draft.start..<draft.end).formatted(.interval.hour().minute())
    }
}
