import AppKit
import Combine
import EventKit
import SwiftUI

/// Calendar: the next event on Home, an agenda tab with a month grid and quick add, and an
/// alert in the notch a few minutes before each meeting. Reads every calendar in the
/// Calendar app through EventKit, with full access asked for once when it's turned on.
@MainActor
final class CalendarFeature: Feature {
    private struct Settings: Equatable {
        var enabled: Bool
        var days: Int
        var lead: Int          // minutes before a meeting that its alert appears; 0 is off
    }

    private let context: AppContext
    let model: CalendarModel
    private var source: CalendarEventSource?
    private var settings: Settings?
    private var timer: Timer?
    private var alertTimer: Timer?        // one shot, at the next alert opening or countdown change
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var configWatch: AnyCancellable?
    private var notchWatch: AnyCancellable?
    private var tabShowing = false
    private var armedKeyboard = false
    private var refreshWork: DispatchWorkItem?
    private var messageWork: DispatchWorkItem?
    private var generation = 0
    private var refreshedDay: Date?
    private var gridMonth: Date?          // the month the grid last asked for, reloaded on changes
    private var askedForAccess = false
    private var dismissed: [String: Date] = [:]     // event key → its start; kept a day
    private var dismissedLoaded = false
    private var dismissedFile: JSONFile<[String: Date]>?

    init(context: AppContext) {
        self.context = context
        self.model = CalendarModel(access: .off, now: Date())
    }

    func start() {
        let model = self.model
        let notch = context.model
        model.actions = CalendarActions(
            requestAccess: { [weak self] in self?.requestAccess() },
            enable: { notch.updateConfig { $0.calendarEnabled = true } },
            openPrivacySettings: { Self.openPrivacySettings() },
            openTab: { notch.select(.calendar) },
            close: { notch.close() },
            loadMonth: { [weak self] month in self?.loadMonth(month) },
            browse: { [weak self] day in self?.browse(day) },
            save: { [weak self] draft in self?.save(draft) },
            startTyping: { [weak self] in self?.armKeyboard() },
            join: { [weak self] event in
                guard let url = event.link?.url else { return }
                NSWorkspace.shared.open(url)
                self?.joined(event)
                // You're off to the meeting; the open panel would sit over the menu bar.
                if !notch.pinned { notch.close() }
            })

        context.registerTab(.calendar) { CalendarTabView(model: model) }
        context.registerHomeCard { CalendarHomeCard(model: model) }
        context.model.onTabShown[.calendar] = { [weak self] in self?.tabShown() }
        // The tab is a glance, like Home: it takes typing only after a click in quick add.
        notch.keyboardTabs.remove(.calendar)
        // objectWillChange fires before the change lands; look once it has.
        notchWatch = notch.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.notchChanged() } }

        dismissedFile = JSONFile(url: context.dataURL("calendar-dismissed.json"))
        loadDismissed()
        // Fires now with the current settings, then before every change lands.
        configWatch = context.model.$config.sink { [weak self] config in
            MainActor.assumeIsolated { self?.apply(config) }
        }
    }

    func stop() {
        configWatch = nil
        notchWatch = nil
        disarmKeyboard()
        settings = nil          // loads still in flight then post no alerts
        generation += 1
        timer?.invalidate()
        timer = nil
        alertTimer?.invalidate()
        alertTimer = nil
        removeObservers()
        refreshWork?.cancel()
        messageWork?.cancel()
        context.activities.removeAll(prefix: "calendar.")
    }

    // MARK: Settings and access

    private func apply(_ config: Config) {
        let next = Settings(enabled: config.calendarEnabled, days: config.calendarDays, lead: config.meetingAlertMinutes)
        guard next != settings else { return }
        let before = settings
        settings = next
        model.days = next.days + 1
        if !next.enabled {
            disable()
        } else if before?.enabled != true {
            enable()
        } else if before?.days != next.days {
            refresh()
        } else {
            checkAlerts()
        }
    }

    private func enable() {
        if source == nil { source = CalendarEventSource() }
        observeChanges()
        startTimer()
        updateAccess(ask: !askedForAccess)
    }

    private func disable() {
        timer?.invalidate()
        timer = nil
        alertTimer?.invalidate()
        alertTimer = nil
        removeObservers()
        refreshWork?.cancel()
        generation += 1
        model.access = .off
        clearEvents()
        disarmKeyboard()
    }

    /// Reads the permission state; with `ask`, shows macOS's prompt if it hasn't been
    /// answered (once per launch, or when you click Allow Access).
    private func updateAccess(ask: Bool) {
        guard settings?.enabled == true else { return }
        let status = CalendarEventSource.status
        if status == .fullAccess {
            if model.access != .granted {
                // A store made before access was granted keeps seeing nothing. That includes
                // one kept from before Calendar was turned off.
                source?.reset()
                model.access = .granted
                refresh()
            }
            return
        }
        if ask && (status == .notDetermined || status == .writeOnly) {
            requestAccess()
            return
        }
        let access: CalendarModel.Access = status == .notDetermined ? .notDetermined : .denied
        if model.access != access {
            model.access = access
            clearEvents()
            disarmKeyboard()        // the tab shows the access notice; there's no field to type in
        }
    }

    private func requestAccess() {
        guard settings?.enabled == true, let source else { return }
        askedForAccess = true
        if model.access == .granted { return }
        model.access = .notDetermined
        Task { [weak self] in
            let granted = await source.requestAccess()
            CalendarLog.logger.info("calendar access \(granted ? "granted" : "not granted", privacy: .public)")
            self?.updateAccess(ask: false)
        }
    }

    private func clearEvents() {
        model.upcoming = []
        model.loaded = false
        model.browseEvents = nil
        model.busyDays = []
        context.activities.removeAll(prefix: CalendarAlerts.prefix)
    }

    // MARK: Loading

    /// Reloads today through `calendarDays` ahead, plus whatever the tab is browsing.
    private func refresh() {
        refreshWork?.cancel()
        refreshWork = nil
        guard model.access == .granted, let source else { return }
        generation += 1
        let current = generation
        let calendar = model.calendar
        let from = calendar.startOfDay(for: Date())
        guard let to = calendar.date(byAdding: .day, value: model.days, to: from) else { return }
        // After midnight the grid follows today, unless you've picked a day.
        if let previous = refreshedDay, previous != from, model.selectedDay == nil, model.browseStart == nil {
            model.month = CalendarMonthLayout.monthStart(from, calendar: calendar)
            if gridMonth != nil { gridMonth = model.month }
        }
        refreshedDay = from
        Task { [weak self] in
            let events = await source.events(from: from, to: to)
            guard let self, current == self.generation else { return }
            self.model.upcoming = events
            self.model.loaded = true
            self.checkAlerts()
        }
        if let start = model.browseStart { browse(start) }
        if let gridMonth { loadMonth(gridMonth) }
    }

    /// EventKit posts a burst of change notifications for one edit; wait for it to settle.
    private func scheduleRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func browse(_ day: Date) {
        guard model.access == .granted, let source,
              let end = model.calendar.date(byAdding: .day, value: model.days, to: day) else { return }
        Task { [weak self] in
            let events = await source.events(from: day, to: end)
            guard let self, self.model.browseStart == day else { return }
            self.model.browseEvents = events
        }
    }

    private func loadMonth(_ month: Date) {
        gridMonth = month
        let calendar = model.calendar
        let days = CalendarMonthLayout.days(month: month, calendar: calendar)
        guard model.access == .granted, let source, let first = days.first, let last = days.last,
              let end = calendar.date(byAdding: .day, value: 1, to: last) else { return }
        Task { [weak self] in
            let events = await source.events(from: first, to: end, details: false)
            guard let self, self.model.month == month else { return }
            self.model.busyDays = CalendarAgenda.busyDays(events, from: first, to: end, calendar: calendar)
        }
    }

    /// One save at a time: Return pressed again, or held down, while EventKit commits would
    /// add the event again.
    private func save(_ draft: CalendarQuickAdd.Draft) {
        guard model.access == .granted, let source, !model.saving else { return }
        model.saving = true
        let submitted = model.draftText
        Task { [weak self] in
            let result = await source.save(draft)
            guard let self else { return }
            self.model.saving = false
            switch result {
            case .saved(let calendar):
                if self.model.draftText == submitted { self.model.draftText = "" }   // keep text typed during the save
                self.show("Added to \(calendar)")
                // Done typing: hand the keyboard back to your app.
                if self.model.draftText.isEmpty { self.disarmKeyboard() }
                self.refresh()
                self.model.pick(draft.start)
            case .failed(let reason):
                self.show("Couldn't add: \(reason)")
            }
        }
    }

    private func show(_ message: String) {
        model.message = message
        messageWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.model.message = nil }
        }
        messageWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func tabShown() {
        if settings?.enabled == true && model.access != .granted { updateAccess(ask: false) }
    }

    // MARK: Keyboard

    /// A click on quick add makes the panel the key window and focuses the field. As with
    /// the other typing tabs, moving the pointer away then no longer closes it; a click
    /// elsewhere or Esc on an empty field does. Never without access: there's no field.
    private func armKeyboard() {
        let notch = context.model
        guard model.access == .granted, notch.isOpen, notch.currentTab == .calendar else { return }
        if !armedKeyboard {
            armedKeyboard = true
            notch.keyboardTabs.insert(.calendar)
            model.typing = true
            notch.objectWillChange.send()      // the window controller re-checks key status on changes
        }
        model.focusRequest += 1
    }

    private func disarmKeyboard() {
        guard armedKeyboard else { return }
        armedKeyboard = false
        let notch = context.model
        notch.keyboardTabs.remove(.calendar)
        model.typing = false
        // Still on screen (after a save): the window controller hands key status back.
        if notch.isOpen && notch.currentTab == .calendar { notch.objectWillChange.send() }
    }

    /// When the tab leaves the screen (the panel closes or another tab shows), quick add
    /// lets go of the keyboard.
    private func notchChanged() {
        let notch = context.model
        let showing = notch.isOpen && notch.currentTab == .calendar
        defer { tabShowing = showing }
        guard tabShowing, !showing else { return }
        disarmKeyboard()
    }

    // MARK: Meeting alerts

    /// Every 30 s: moves the views' clock, reloads after midnight, and posts, updates or
    /// removes meeting alerts (`alertTimer` catches the exact minutes; this is the safety
    /// net). Also rechecks access, so granting it in System Settings shows
    /// up without a restart, and revoking it clears the events and alerts.
    private func tick() {
        updateAccess(ask: false)
        let now = Date()
        if let day = refreshedDay, !model.calendar.isDate(now, inSameDayAs: day) { refresh() }
        checkAlerts(now: now)
    }

    private func checkAlerts(now: Date = Date()) {
        if !model.calendar.isDate(now, equalTo: model.now, toGranularity: .minute) { model.now = now }
        guard let settings, settings.enabled, model.access == .granted, dismissedLoaded else {
            alertTimer?.invalidate()
            alertTimer = nil
            if model.access != .granted { context.activities.removeAll(prefix: CalendarAlerts.prefix) }
            return
        }
        let meetings = CalendarAlerts.merged(model.upcoming)
        let dismissedKeys = Set(dismissed.keys)
        let due = CalendarAlerts.due(meetings, now: now, leadMinutes: settings.lead, dismissed: dismissedKeys)
        let dueIDs = Set(due.map(CalendarAlerts.activityID))
        for shown in context.activities.activities where shown.id.hasPrefix(CalendarAlerts.prefix) && !dueIDs.contains(shown.id) {
            context.activities.remove(id: shown.id)
        }
        for event in due {
            let fresh = CalendarAlerts.activity(event, now: now)
            if let shown = context.activities.activity(id: fresh.id) {
                guard shown.accessory != fresh.accessory || shown.title != fresh.title || shown.subtitle != fresh.subtitle
                        || shown.actions != fresh.actions || shown.symbol != fresh.symbol else { continue }
                context.activities.update(id: fresh.id) { a in
                    a.accessory = fresh.accessory
                    a.title = fresh.title
                    a.subtitle = fresh.subtitle
                    a.actions = fresh.actions
                    a.symbol = fresh.symbol
                }
            } else {
                // The center expires alerts on its own clock; don't bring one back for its
                // last few seconds if the wall clock disagrees slightly.
                guard event.start.addingTimeInterval(CalendarAlerts.linger).timeIntervalSince(now) > 5 else { continue }
                let key = event.key
                let link = event.link?.url
                context.activities.post(fresh) { [weak self] action in
                    self?.alertAction(action, key: key, link: link)
                }
            }
        }
        armNextAlert(at: CalendarAlerts.nextChange(meetings, now: now, leadMinutes: settings.lead, dismissed: dismissedKeys),
                     now: now)
    }

    /// Wakes up when the next alert opens or a countdown changes, so alerts keep to the
    /// minute instead of the 30 s tick, which stays as a safety net. At most an hour ahead:
    /// timers stop while the Mac sleeps, and the wake observer and the tick re-arm it.
    private func armNextAlert(at change: Date?, now: Date) {
        alertTimer?.invalidate()
        alertTimer = nil
        guard let change else { return }
        // A moment after: the timer runs on uptime, the check on the wall clock.
        let fire = min(change, now.addingTimeInterval(3600)).addingTimeInterval(0.25)
        let t = Timer(fire: fire, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAlerts() }
        }
        t.tolerance = 0.25
        RunLoop.main.add(t, forMode: .common)
        alertTimer = t
    }

    private func alertAction(_ action: String, key: String, link: URL?) {
        let event = CalendarAlerts.merged(model.upcoming).first { $0.key == key }
        if action == "join", let url = event?.link?.url ?? link {
            NSWorkspace.shared.open(url)
        }
        // Joining also dismisses: the alert has done its job.
        dismissAlert(key: key, start: event?.start ?? Date())
    }

    /// Join on the Home card or in the agenda: the alert has done its job too. Only for a
    /// meeting whose alert is up or about to be; joining tomorrow's early keeps tomorrow's.
    private func joined(_ event: CalendarEvent) {
        let lead = Double(settings?.lead ?? 0) * 60
        let now = Date()
        guard now >= event.start.addingTimeInterval(-max(lead, 15 * 60)),
              now < event.start.addingTimeInterval(CalendarAlerts.linger) else { return }
        dismissAlert(key: event.key, start: event.start)
    }

    /// Records the dismissal under every copy's key (the meeting in other calendars), so the
    /// alert stays gone whichever copy shows it after a reload.
    private func dismissAlert(key: String, start: Date) {
        dismissed[key] = start
        context.activities.remove(id: CalendarAlerts.prefix + key)
        if let event = model.upcoming.first(where: { $0.key == key }) {
            for copy in model.upcoming where CalendarAlerts.sameMeeting(copy, event) {
                dismissed[copy.key] = copy.start
                context.activities.remove(id: CalendarAlerts.activityID(copy))
            }
        }
        saveDismissed()
    }

    private func loadDismissed() {
        guard let file = dismissedFile else {
            dismissedLoaded = true
            return
        }
        Task { [weak self] in
            let saved = await Self.read(file)
            guard let self else { return }
            self.dismissed.merge(saved) { mine, _ in mine }
            self.dismissedLoaded = true
            self.checkAlerts()
        }
    }

    private func saveDismissed() {
        let cutoff = Date().addingTimeInterval(-86_400)
        dismissed = dismissed.filter { $0.value > cutoff }
        guard let file = dismissedFile else { return }
        let snapshot = dismissed
        // One serial queue, so two quick dismissals can't land on disk out of order.
        Self.fileQueue.async { file.save(snapshot) }
    }

    private static let fileQueue = DispatchQueue(label: "local.dynamicnotch.calendar.files", qos: .utility)

    /// Off the main actor: a file read.
    nonisolated private static func read(_ file: JSONFile<[String: Date]>) async -> [String: Date] {
        file.load() ?? [:]
    }

    // MARK: Timers and notifications

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)     // keeps ticking while a menu is open
        timer = t
    }

    private func observeChanges() {
        guard observers.isEmpty else { return }
        // Also posted when access changes: a grant or revocation applies at once, not on the tick.
        observe(NotificationCenter.default, .EKEventStoreChanged) {
            $0.updateAccess(ask: false)
            $0.scheduleRefresh()
        }
        observe(NotificationCenter.default, .NSCalendarDayChanged) { $0.refresh() }
        observe(NotificationCenter.default, .NSSystemTimeZoneDidChange) { $0.refresh() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) {
            $0.updateAccess(ask: false)
            $0.refresh()
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ action: @escaping @Sendable @MainActor (CalendarFeature) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        observers.append((center, token))
    }

    private func removeObservers() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }

    private static func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else { return }
        NSWorkspace.shared.open(url)
    }
}

extension CalendarFeature {
    func debugState() -> [String: Any] {
        ["access": String(describing: model.access), "loaded": model.loaded, "upcoming": model.upcoming.count]
    }
}
