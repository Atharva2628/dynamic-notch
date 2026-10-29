import Foundation
import SwiftUI

extension CalendarFeature {
    /// Pure-logic checks: link detection, quick-add parsing against a fixed date, the alert
    /// window, day grouping, the month grid and the model's day picking.
    @MainActor static func selfTest(_ check: (Bool, String) -> Void) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago") ?? .gmt
        cal.locale = Locale(identifier: "en_US_POSIX")
        cal.firstWeekday = 1
        func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
            cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s)) ?? .distantPast
        }
        func oct26(_ h: Int, _ mi: Int = 0, _ s: Int = 0) -> Date { at(2026, 10, 26, h, mi, s) }

        // Meeting links.
        let zoom = CalendarLinks.find(url: nil, location: "https://us02web.zoom.us/j/88123456789?pwd=abc", notes: nil)
        check(zoom?.service == .zoom && zoom?.url.host == "us02web.zoom.us", "calendar: finds a Zoom link in the location")
        let meet = CalendarLinks.find(url: nil, location: "Room 4",
                                      notes: "Join with Google Meet: meet.google.com/abc-defg-hij\nJoin by phone: +1 555-0100")
        check(meet?.service == .meet && meet?.url.absoluteString == "https://meet.google.com/abc-defg-hij",
              "calendar: finds a Meet link without a scheme in the notes, as https")
        let teams = CalendarLinks.first(in: """
            Microsoft Teams meeting
            Join: <https://teams.microsoft.com/l/meetup-join/19%3ameeting_NjQ%40thread.v2/0?context=%7b%22Tid%22%3a%22x%22%7d>
            Help: https://aka.ms/JoinTeamsMeeting
            """)
        check(teams?.service == .teams, "calendar: finds a Teams meetup-join link")
        check(CalendarLinks.first(in: "Webex: https://acme.webex.com/acme/j.php?MTID=m0123")?.service == .webex,
              "calendar: finds a Webex link")
        check(CalendarLinks.first(in: "See https://zoom.us/support, https://www.webex.com/downloads.html and https://example.com/j/1") == nil,
              "calendar: help pages and other links aren't meetings")
        check(CalendarLinks.find(url: URL(string: "https://zoom.us/j/1"), location: nil,
                                 notes: "https://meet.google.com/abc-defg-hij")?.service == .zoom,
              "calendar: the event's URL wins over its notes")
        check(CalendarLinks.find(url: nil, location: "http://meet.google.com/abc-defg-hij", notes: nil)?.url.scheme == "https",
              "calendar: meeting links are upgraded to https")

        // Quick add against a fixed reference date: Monday Oct 26 2026, 16:30.
        let ref = oct26(16, 30)
        func draft(_ text: String, _ phrase: String, _ date: Date, duration: TimeInterval = 0,
                   length: TimeInterval? = nil) -> CalendarQuickAdd.Draft {
            let match = CalendarQuickAdd.Match(range: (text as NSString).range(of: phrase), date: date, duration: duration)
            return CalendarQuickAdd.draft(text, match: match, length: length, now: ref, calendar: cal)
        }
        let lunch = draft("lunch fri 1pm", "lunch fri 1pm", at(2026, 10, 30, 13))
        check(lunch.title == "lunch" && lunch.start == at(2026, 10, 30, 13) && lunch.end == at(2026, 10, 30, 14) && !lunch.isAllDay,
              "calendar: quick add keeps a meal word the detector took, and lasts 1 h")
        check(draft("Lunch with Sam on Friday at 1pm", "Friday at 1pm", at(2026, 10, 30, 13)).title == "Lunch with Sam",
              "calendar: quick add drops the 'on' left before the date")
        check(draft("Lunch with Sam fri 1pm at Tartine", "fri 1pm", at(2026, 10, 30, 13)).title == "Lunch with Sam at Tartine",
              "calendar: quick add keeps the words after the date")
        let party = draft("party dec 24", "dec 24", at(2026, 12, 24, 12))
        check(party.isAllDay && party.start == at(2026, 12, 24) && party.end == at(2026, 12, 25) && party.title == "party",
              "calendar: a day without a time makes an all-day event")
        check(draft("call 3pm", "3pm", oct26(15)).start == at(2026, 10, 27, 15),
              "calendar: a time already past today means tomorrow")
        check(draft("sync mon 10am", "mon 10am", oct26(10)).start == at(2026, 11, 2, 10),
              "calendar: today's weekday at a past time means next week")
        check(draft("review oct 1", "oct 1", at(2026, 10, 1, 12)).start == at(2027, 10, 1),
              "calendar: a past date without a year means next year")
        let (cleaned, length) = CalendarQuickAdd.extractLength("sync fri 10am for 30 min")
        let sync = draft(cleaned, "fri 10am", at(2026, 10, 30, 10), length: length)
        check(length == 1800 && sync.title == "sync" && sync.end == at(2026, 10, 30, 10, 30),
              "calendar: 'for 30 min' sets the length and leaves the title")
        let trip = draft("trip nov 5 - nov 8", "nov 5 - nov 8", at(2026, 11, 5, 12), duration: 3 * 86_400)
        check(trip.isAllDay && trip.start == at(2026, 11, 5) && trip.end == at(2026, 11, 9),
              "calendar: a date range makes a multi-day all-day event")
        check(CalendarQuickAdd.parse("groceries", now: ref, calendar: cal) == nil, "calendar: no day or time, nothing to add")
        let six = draft("call mom tomorrow at 6", "tomorrow at 6", at(2026, 10, 27, 18))
        check(!six.isAllDay && six.start == at(2026, 10, 27, 18) && six.title == "call mom"
              && !draft("call tomorrow at 12", "tomorrow at 12", at(2026, 10, 27, 12)).isAllDay
              && !draft("dinner 7 o'clock", "7 o'clock", oct26(19)).isAllDay,
              "calendar: a time the detector read without am/pm isn't all-day ('at 6', 'at 12', 'o'clock')")

        // The same through NSDataDetector, which reads relative dates from the real clock.
        let local = Calendar.current
        let dentist = CalendarQuickAdd.parse("dentist 3 Dec 2027 at 9:30am", now: Date(), calendar: local)
        let dc = dentist.map { local.dateComponents([.year, .month, .day, .hour, .minute], from: $0.start) }
        check(dentist?.title == "dentist" && dc?.year == 2027 && dc?.month == 12 && dc?.day == 3 && dc?.hour == 9 && dc?.minute == 30,
              "calendar: NSDataDetector reads a full date and the rest is the title")
        let now = Date()
        let friday = CalendarQuickAdd.parse("lunch fri 1pm", now: now, calendar: local)
        let fc = friday.map { local.dateComponents([.weekday, .hour, .minute], from: $0.start) }
        check(friday?.title == "lunch" && fc?.weekday == 6 && fc?.hour == 13 && fc?.minute == 0
              && (friday.map { $0.start > now && $0.start < now.addingTimeInterval(8 * 86_400) } ?? false),
              "calendar: 'lunch fri 1pm' is the coming Friday at 1 pm")
        // The detector puts a day alone at exactly noon and keeps a time it read; `draft` relies on it.
        let call = CalendarQuickAdd.parse("call mom tomorrow at 6", now: now, calendar: local)
        let tomorrow = CalendarQuickAdd.parse("party tomorrow", now: now, calendar: local)
        check(call?.isAllDay == false && call?.title == "call mom" && tomorrow?.isAllDay == true && tomorrow?.title == "party",
              "calendar: NSDataDetector gives 'tomorrow at 6' a time and leaves 'tomorrow' a whole day")

        // Meeting alerts: 10:00 to 10:30 with a Zoom link, alerting 5 min ahead.
        let meeting = CalendarEvent(id: "m1", title: "Design review", start: oct26(10), end: oct26(10, 30),
                                    link: URL(string: "https://zoom.us/j/1").flatMap(CalendarLinks.link))
        func due(_ e: CalendarEvent, _ t: Date, lead: Int = 5, dismissed: Set<String> = []) -> Bool {
            CalendarAlerts.isDue(e, now: t, leadMinutes: lead, dismissed: dismissed)
        }
        check(!due(meeting, oct26(9, 54, 59)) && due(meeting, oct26(9, 55)), "calendar: the alert appears 5 min before")
        check(due(meeting, oct26(10, 4, 59)) && !due(meeting, oct26(10, 5)), "calendar: the alert goes 5 min after the start")
        check(!due(meeting, oct26(9, 58), dismissed: ["m1"]), "calendar: a dismissed meeting doesn't alert again")
        var allDay = meeting
        allDay.isAllDay = true
        var declined = meeting
        declined.declined = true
        check(!due(allDay, oct26(9, 58)) && !due(declined, oct26(9, 58)) && !due(meeting, oct26(9, 58), lead: 0),
              "calendar: no alert for all-day or declined events, or with a lead of 0")
        check(CalendarAlerts.countdown(to: meeting.start, now: oct26(9, 55)) == "5 min"
              && CalendarAlerts.countdown(to: meeting.start, now: oct26(9, 59, 30)) == "1 min"
              && CalendarAlerts.countdown(to: meeting.start, now: oct26(10)) == "Now",
              "calendar: the alert counts down by the minute, then says Now")
        let alert = CalendarAlerts.activity(meeting, now: oct26(9, 55))
        var noLink = meeting
        noLink.link = nil
        check(alert.id == "calendar.meeting.m1" && alert.priority == .alert && alert.urgent && alert.opensTab == .calendar
              && alert.accessory == .text("5 min") && alert.actions.map(\.id) == ["join", "dismiss"]
              && CalendarAlerts.activity(noLink, now: oct26(9, 55)).actions.map(\.id) == ["dismiss"],
              "calendar: the alert is urgent, opens the tab, and offers Join only with a link")
        check(alert.duration == 600 && CalendarAlerts.activity(meeting, now: oct26(10, 4, 30)).duration == 30,
              "calendar: the alert expires exactly 5 min after the start")
        func change(_ t: Date, dismissed: Set<String> = []) -> Date? {
            CalendarAlerts.nextChange([meeting], now: t, leadMinutes: 5, dismissed: dismissed)
        }
        check(change(oct26(9, 50)) == oct26(9, 55) && change(oct26(9, 55)) == oct26(9, 56)
              && change(oct26(9, 59, 30)) == oct26(10) && change(oct26(10, 1)) == nil
              && change(oct26(9, 50), dismissed: ["m1"]) == nil,
              "calendar: alerts wake up when they open, on each minute of the countdown, and at the start")

        // One meeting in two calendars: the same UID, different event ids.
        var work = meeting
        work.id = "m1-work"
        work.uid = "UID1"
        var mail = work
        mail.id = "m1-mail"
        mail.link = nil
        var mailDeclined = mail
        mailDeclined.declined = true
        var delegate = mail
        delegate.id = "m1-delegate"
        delegate.uid = "UID2"            // an Exchange delegate copy: the same title and start
        func dueNow(_ events: [CalendarEvent]) -> [String] {
            CalendarAlerts.due(CalendarAlerts.merged(events), now: oct26(9, 58), leadMinutes: 5, dismissed: []).map(\.id)
        }
        check(work.key == mail.key && dueNow([mail, work]) == ["m1-work"] && dueNow([work, delegate]) == ["m1-work"],
              "calendar: a meeting in two calendars alerts once, from the copy with a link")
        check(dueNow([mailDeclined, work]).isEmpty, "calendar: a meeting declined in one calendar doesn't alert from the other")
        check(!due(work, oct26(9, 58), dismissed: [mail.key]), "calendar: dismissing one copy dismisses the meeting")

        // Agenda grouping, at 16:30 on Monday.
        let today = at(2026, 10, 26)
        let events = [
            CalendarEvent(id: "ended", title: "Standup", start: oct26(9), end: oct26(9, 30)),
            CalendarEvent(id: "late", title: "Gym", start: oct26(18), end: oct26(19)),
            CalendarEvent(id: "allday", title: "Ship M4", start: today, end: oct26(23, 59, 59), isAllDay: true),
            CalendarEvent(id: "overnight", title: "Deploy", start: at(2026, 10, 28, 22), end: at(2026, 10, 29, 2)),
        ]
        let days = CalendarAgenda.group(events, from: ref, days: 8, now: ref, keep: [today], calendar: cal)
        check(days.map(\.date) == [today, at(2026, 10, 28), at(2026, 10, 29)],
              "calendar: one section per day with events, today first, empty days skipped")
        check(days.first?.events.map(\.id) == ["allday", "ended", "late"],
              "calendar: today lists all-day events first and keeps only the last event that ended")
        let rows = CalendarTimeline.rows(events, now: ref, calendar: cal)
        check(rows.previous?.id == "ended" && rows.current?.id == "allday" && rows.next?.id == "late",
              "calendar: Earlier is the last event that ended, Now falls back to today's all-day event, Next is the next timed one")
        var inMeeting = events
        inMeeting.append(CalendarEvent(id: "now", title: "Review", start: oct26(16), end: oct26(17)))
        inMeeting.append(CalendarEvent(id: "earlier", title: "Lunch", start: oct26(12), end: oct26(13)))
        let busy = CalendarTimeline.rows(inMeeting, now: ref, calendar: cal)
        check(busy.previous?.id == "earlier" && busy.current?.id == "now" && busy.next?.id == "late",
              "calendar: a meeting under way is Now, and the latest one to end is Earlier")
        check(CalendarTimeline.free(next: events[1], now: ref, calendar: cal).hasPrefix("until ")
              && CalendarTimeline.free(next: nil, now: ref, calendar: cal) == "for the rest of the day"
              && CalendarTimeline.ended(events[0], now: oct26(9, 40)) == "ended 10 min ago",
              "calendar: free-until and ended texts")
        check(days.dropFirst().allSatisfy { $0.events.map(\.id) == ["overnight"] }, "calendar: an overnight event shows on both days")
        let kept = CalendarAgenda.group(events, from: ref, days: 8, now: ref, keep: [today, at(2026, 10, 27)], calendar: cal)
        check(kept.contains { $0.date == at(2026, 10, 27) && $0.events.isEmpty }, "calendar: a picked day gets a section even when empty")
        check(CalendarAgenda.busyDays(events, from: today, to: at(2026, 11, 2), calendar: cal)
              == [today, at(2026, 10, 28), at(2026, 10, 29)], "calendar: the month grid marks days with events")

        // Month grid and day picking.
        let grid = CalendarMonthLayout.days(month: at(2026, 10, 15), calendar: cal)
        check(grid.count == 42 && grid.first == at(2026, 9, 27) && grid.contains(at(2026, 10, 31)),
              "calendar: October 2026's grid starts on Sunday Sep 27")
        var monday = cal
        monday.firstWeekday = 2
        check(CalendarMonthLayout.weekdaySymbols(calendar: cal).first == "S"
              && CalendarMonthLayout.weekdaySymbols(calendar: monday).first == "M"
              && CalendarMonthLayout.weekdaySymbols(calendar: monday).count == 7
              && CalendarMonthLayout.days(month: at(2026, 10, 1), calendar: monday).first == at(2026, 9, 28),
              "calendar: the grid follows the locale's first weekday")
        let model = CalendarModel(access: .granted, now: ref, calendar: cal)
        var browsed: [Date] = []
        model.actions.browse = { browsed.append($0) }
        model.pick(at(2026, 10, 29))
        check(model.browseStart == nil && model.scrollTarget == at(2026, 10, 29) && browsed.isEmpty,
              "calendar: picking a listed day scrolls to it")
        model.pick(at(2026, 11, 20, 15))
        check(model.browseStart == at(2026, 11, 20) && browsed == [at(2026, 11, 20)] && model.month == at(2026, 11, 1),
              "calendar: picking a later day starts the agenda there and shows its month")
        model.goToday()
        check(model.browseStart == nil && model.isAtToday, "calendar: Today goes back")

        // Quick-add keys: Return saves only a parsed event, Esc clears before it closes.
        var saved: [CalendarQuickAdd.Draft] = []
        var closes = 0
        model.actions.save = { saved.append($0) }
        model.actions.close = { closes += 1 }
        model.draftText = "groceries"
        model.submit()
        model.escape()
        check(saved.isEmpty && model.draftText.isEmpty && closes == 0,
              "calendar: Return does nothing without a day or time, and Esc clears the text first")
        model.escape()
        check(closes == 1, "calendar: Esc on an empty field closes the notch")
        model.actions.save = { saved.append($0); model.saving = true }      // a save that hasn't finished
        model.draftText = "lunch fri 1pm"
        model.submit()
        model.submit()
        check(saved.count == 1, "calendar: Return again while a quick add saves doesn't add it twice")
        model.saving = false
        model.message = "Couldn't add: no calendar to add to"
        model.draftText = ""
        let messageKept = model.message != nil
        model.draftText = "lunch fri 2pm"
        check(messageKept && model.message == nil, "calendar: a quick-add message stays until you type")

        // Home card text.
        check(CalendarFormat.until(meeting, now: oct26(9, 35), calendar: cal) == "in 25 min"
              && CalendarFormat.until(meeting, now: oct26(10, 10), calendar: cal) == "Now"
              && CalendarFormat.until(meeting, now: oct26(7, 55), calendar: cal) == "in 2 h 5 min",
              "calendar: time until the next event")
        let wed = CalendarEvent(id: "w", title: "Wed", start: at(2026, 10, 28, 10), end: at(2026, 10, 28, 11))
        let later = CalendarEvent(id: "l", title: "Later", start: at(2026, 11, 3, 10), end: at(2026, 11, 3, 11))
        check(CalendarFormat.until(wed, now: ref, calendar: cal) == "Wednesday"
              && CalendarFormat.until(later, now: ref, calendar: cal) == "Nov 3",
              "calendar: a weekday this week, a date a week or more out")
        check(CalendarFormat.rowTimes(events[3], day: at(2026, 10, 29), calendar: cal).top == "…"
              && CalendarFormat.rowTimes(events[3], day: at(2026, 10, 28), calendar: cal).bottom == "→",
              "calendar: an overnight event's rows show where it continues")
        let card = CalendarModel(access: .granted, now: ref, calendar: cal)
        card.upcoming = events
        check(card.nextEvents.next?.id == "late" && card.nextEvents.then?.id == "overnight",
              "calendar: the Home card shows the next timed event and the one after, skipping what has ended")
        var gym = events[1]
        gym.uid = "UID3"
        var gymCopy = gym
        gymCopy.id = "late-copy"
        card.upcoming = [gymCopy, gym]
        check(card.nextEvents.next?.title == "Gym" && card.nextEvents.then == nil,
              "calendar: the Home card counts a meeting in two calendars once")
        card.upcoming = events.filter { $0.id == "allday" }
        check(card.nextEvents.next?.id == "allday" && CalendarFormat.until(events[2], now: ref, calendar: cal) == "Today",
              "calendar: with no timed events left, the Home card shows today's all-day event")
    }

    /// The tab and the Home card with sample events, plus their no-access versions.
    @MainActor static func snapshotViews() -> [(name: String, view: AnyView)] {
        let typing = CalendarSamples.model()
        typing.typing = true
        typing.draftText = "lunch fri 1pm"
        func tab(_ model: CalendarModel) -> AnyView {
            AnyView(CalendarTabView(model: model)
                .frame(width: 758, height: 186)
                .background(Color.black)
                .environment(\.colorScheme, .dark))
        }
        func card(_ model: CalendarModel) -> AnyView {
            AnyView(CalendarHomeCard(model: model)
                .frame(width: 145, height: 186)
                .background(NotchStyle.card, in: RoundedRectangle(cornerRadius: NotchStyle.cornerRadius, style: .continuous))
                .background(Color.black)
                .environment(\.colorScheme, .dark))
        }
        return [
            ("calendar-tab", tab(CalendarSamples.model())),
            ("calendar-tab-quick-add", tab(typing)),
            ("calendar-tab-no-access", tab(CalendarSamples.model(access: .denied))),
            ("calendar-card", card(CalendarSamples.model())),
            ("calendar-card-no-access", card(CalendarSamples.model(access: .denied))),
        ]
    }
}

/// Sample events for snapshots: Monday Oct 26 2026 at 10:35, a Zoom meeting in 5 minutes.
enum CalendarSamples {
    @MainActor static func model(access: CalendarModel.Access = .granted) -> CalendarModel {
        let cal = Calendar.current
        func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m)) ?? Date()
        }
        let work = CalendarColor(red: 0.25, green: 0.56, blue: 1)
        let home = CalendarColor(red: 1, green: 0.62, blue: 0.22)
        let personal = CalendarColor(red: 0.66, green: 0.45, blue: 0.98)
        let zoom = URL(string: "https://zoom.us/j/88123456789").flatMap(CalendarLinks.link)
        let meet = URL(string: "https://meet.google.com/abc-defg-hij").flatMap(CalendarLinks.link)
        let events = [
            CalendarEvent(id: "s1", title: "Standup", start: at(26, 9, 30), end: at(26, 9, 45),
                          calendarTitle: "Work", color: work, link: meet),
            CalendarEvent(id: "s2", title: "Ship M4", start: at(26, 0), end: at(26, 23, 59), isAllDay: true,
                          calendarTitle: "Work", color: work),
            CalendarEvent(id: "s3", title: "Design review", start: at(26, 10, 40), end: at(26, 11, 30),
                          calendarTitle: "Work", color: work, link: zoom),
            CalendarEvent(id: "s4", title: "Lunch with Sam", start: at(26, 12, 30), end: at(26, 13, 30),
                          calendarTitle: "Home", color: home, location: "Tartine"),
            CalendarEvent(id: "s5", title: "1:1 with Ana", start: at(26, 15), end: at(26, 15, 30),
                          calendarTitle: "Work", color: work, link: meet),
            CalendarEvent(id: "s6", title: "Dentist", start: at(27, 9, 30), end: at(27, 10, 30),
                          calendarTitle: "Home", color: home, location: "Dr. Lee"),
            CalendarEvent(id: "s7", title: "Focus block", start: at(27, 13), end: at(27, 16),
                          calendarTitle: "Work", color: work),
            CalendarEvent(id: "s8", title: "Team offsite", start: at(29, 0), end: at(30, 23, 59), isAllDay: true,
                          calendarTitle: "Work", color: work),
            CalendarEvent(id: "s9", title: "Flight to Lisbon", start: at(30, 18, 15), end: at(30, 21, 40),
                          calendarTitle: "Personal", color: personal, location: "Terminal 1"),
        ]
        let model = CalendarModel(access: access, now: at(26, 10, 35), calendar: cal)
        model.isSnapshot = true
        model.upcoming = events
        model.loaded = true
        let grid = CalendarMonthLayout.days(month: model.now, calendar: cal)
        if let first = grid.first, let last = grid.last {
            model.busyDays = CalendarAgenda.busyDays(events, from: first, to: last, calendar: cal)
        }
        return model
    }
}
