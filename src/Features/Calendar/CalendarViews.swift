import SwiftUI

extension CalendarColor {
    var swatch: Color { Color(red: red, green: green, blue: blue) }
}

/// The Calendar tab: quick add over the agenda on the left, the month grid on the right.
struct CalendarTabView: View {
    @ObservedObject var model: CalendarModel

    var body: some View {
        Group {
            if model.access == .granted {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        CalendarQuickAddBar(model: model)
                        CalendarAgendaList(model: model)
                    }
                    // minHeight 0: never taller than the tab, so anything too tall is cut at
                    // the bottom rather than centered with the quick-add bar cut off the top.
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                    CalendarMonthGrid(model: model)
                        .frame(width: 196)
                }
            } else {
                CalendarAccessNotice(model: model, compact: false)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { model.tabAppeared() }
    }
}

/// The Home card: the next event, how long until it starts, and Join when it has a link.
/// A click elsewhere on the card opens the Calendar tab.
struct CalendarHomeCard: View {
    @ObservedObject var model: CalendarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "calendar")
                Text(model.now.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(NotchStyle.secondary)
            Spacer(minLength: 6)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { model.actions.openTab() }
    }

    @ViewBuilder private var content: some View {
        if model.access != .granted {
            CalendarAccessNotice(model: model, compact: true)
        } else if !model.loaded {
            Text("Loading…")
                .font(NotchStyle.bodyFont)
                .foregroundStyle(NotchStyle.tertiary)
        } else {
            timeline(model.timeline)
        }
    }

    /// Earlier, Now and Next, one short row each.
    private func timeline(_ rows: CalendarTimeline.Rows) -> some View {
        let now = model.now
        return VStack(alignment: .leading, spacing: 7) {
            if let previous = rows.previous {
                row("Earlier", previous, detail: CalendarTimeline.ended(previous, now: now), tint: NotchStyle.tertiary)
                    .opacity(0.6)
            } else {
                empty("Earlier", "Nothing yet today", tint: NotchStyle.tertiary)
            }
            if let current = rows.current {
                row("Now", current, detail: current.isAllDay ? "All day" : "until \(CalendarFormat.time(current.end))",
                    tint: .green, join: current.link != nil && !current.isAllDay)
            } else {
                empty("Now", "Free \(CalendarTimeline.free(next: rows.next, now: now, calendar: model.calendar))", tint: .green)
            }
            if let next = rows.next {
                let soon = next.start.timeIntervalSince(now) <= 10 * 60
                row("Next", next, detail: "\(CalendarFormat.until(next, now: now, calendar: model.calendar)) · \(CalendarFormat.shortStart(next, now: now, calendar: model.calendar))",
                    tint: .white, join: soon && next.link != nil)
            } else {
                empty("Next", model.days - 1 == 1 ? "Nothing more today or tomorrow" : "Nothing in the next \(model.days - 1) days",
                      tint: .white)
            }
        }
    }

    private func label(_ text: String, _ tint: Color) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold))
            .kerning(0.4)
            .foregroundStyle(tint)
    }

    private func row(_ title: String, _ event: CalendarEvent, detail: String, tint: Color, join: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            label(title, tint)
            HStack(spacing: 5) {
                Circle().fill(event.color.swatch).frame(width: 6, height: 6)
                Text(event.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if join {
                    Button { model.actions.join(event) } label: {
                        Image(systemName: "video.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 22, height: 16)
                            .background(Color.green, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(event.link.map { "Join on \($0.service.name)" } ?? "Join")
                }
            }
            Text(detail)
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(NotchStyle.secondary)
                .lineLimit(1)
        }
    }

    private func empty(_ title: String, _ text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            label(title, tint)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(NotchStyle.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

// MARK: - Tab parts

/// "lunch fri 1pm" and Return. The parsed event shows on the right as you type. Opening the
/// tab never takes typing from your app: the bar is a placeholder until you click it.
private struct CalendarQuickAddBar: View {
    @ObservedObject var model: CalendarModel
    @FocusState private var focused: Bool
    private let placeholder = "Add an event, like lunch fri 1pm"

    var body: some View {
        let draft = model.draftText.isEmpty ? nil : model.draft
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(model.typing ? Color.white : NotchStyle.secondary)
            field
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            preview(draft)
                .font(NotchStyle.smallFont)
                .lineLimit(1)
                .fixedSize()
        }
        .font(NotchStyle.bodyFont)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(NotchStyle.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            if !model.typing {
                // The feature makes the panel key, then asks for focus.
                Button { model.actions.startTyping() } label: { Color.clear.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
            }
        }
        // On the bar, not the field: the field appears in the same update that asks for focus.
        .onChange(of: model.focusRequest) { focusSoon() }
    }

    @ViewBuilder private var field: some View {
        if model.isSnapshot || !model.typing {
            Text(model.draftText.isEmpty ? placeholder : model.draftText)
                .foregroundStyle(model.draftText.isEmpty ? NotchStyle.tertiary : Color.white)
                .lineLimit(1)
        } else {
            TextField("", text: $model.draftText, prompt: Text(placeholder).foregroundStyle(NotchStyle.tertiary))
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .focused($focused)
                .onSubmit { model.submit() }
                .onExitCommand { model.escape() }
        }
    }

    /// A message comes first, so a failed save says why over the draft it couldn't add;
    /// typing clears it.
    @ViewBuilder private func preview(_ draft: CalendarQuickAdd.Draft?) -> some View {
        if model.saving {
            Text("Adding…").foregroundStyle(NotchStyle.tertiary)
        } else if let message = model.message {
            Text(message).foregroundStyle(NotchStyle.secondary)
        } else if let draft {
            HStack(spacing: 6) {
                // The preview keeps its size, so a long title is cut here rather than squeezing the field.
                Text(draft.title.count > 28 ? draft.title.prefix(27) + "…" : draft.title)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                Text(CalendarFormat.draftSummary(draft, calendar: model.calendar)).foregroundStyle(NotchStyle.secondary)
                Image(systemName: "return").foregroundStyle(NotchStyle.tertiary)
            }
        } else if !model.draftText.isEmpty {
            Text("Add a day or time").foregroundStyle(NotchStyle.tertiary)
        }
    }

    /// Waits a moment so the panel has become the key window first.
    private func focusSoon() {
        guard !model.isSnapshot, model.access == .granted, model.typing else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            focused = true
        }
    }
}

/// Events grouped by day, today first; the month grid scrolls it.
private struct CalendarAgendaList: View {
    @ObservedObject var model: CalendarModel

    var body: some View {
        let loading = !model.loaded || (model.browseStart != nil && model.browseEvents == nil)
        let sections = loading ? [] : model.sections
        if loading {
            Text("Loading…")
                .font(NotchStyle.bodyFont)
                .foregroundStyle(NotchStyle.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 10)
        } else if model.isSnapshot {
            // minHeight 0 makes the frame take the space offered, not the whole list's height.
            rows(sections)
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    rows(sections)
                }
                .scrollIndicators(.never)
                .onChange(of: model.scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .top) }
                    model.scrollTarget = nil
                }
                .onAppear {
                    // A day picked while the list was loading: use it up now, or picking the
                    // same day again later wouldn't count as a change.
                    guard let target = model.scrollTarget else { return }
                    proxy.scrollTo(target, anchor: .top)
                    model.scrollTarget = nil
                }
            }
        }
    }

    private func rows(_ sections: [CalendarAgenda.Day]) -> some View {
        LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
            ForEach(sections) { day in
                Section {
                    if day.events.isEmpty {
                        Text(day.date == model.today ? "Nothing else today" : "No events")
                            .font(NotchStyle.smallFont)
                            .foregroundStyle(NotchStyle.tertiary)
                            .padding(.leading, 13)
                            .padding(.vertical, 4)
                    }
                    ForEach(day.events) { event in
                        CalendarAgendaRow(event: event, day: day.date, model: model)
                    }
                } header: {
                    header(day.date)
                }
            }
        }
    }

    private func header(_ day: Date) -> some View {
        let title = CalendarFormat.dayTitle(day, now: model.now, calendar: model.calendar)
        let relative = ["Today", "Tomorrow", "Yesterday"].contains(title)
        return HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(model.selectedDay == day ? Color.white : Color.white.opacity(0.85))
            if relative {
                Text(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(NotchStyle.smallFont)
                    .foregroundStyle(NotchStyle.tertiary)
            }
        }
        .padding(.vertical, 3)
        .padding(.leading, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black)
        .id(day)
    }
}

private struct CalendarAgendaRow: View {
    let event: CalendarEvent
    let day: Date
    @ObservedObject var model: CalendarModel

    var body: some View {
        let times = CalendarFormat.rowTimes(event, day: day, calendar: model.calendar)
        let live = event.isAttendable && event.start <= model.now && event.end > model.now
        let detail = [event.place, event.calendarTitle.isEmpty ? nil : event.calendarTitle]
            .compactMap { $0 }.joined(separator: " · ")
        HStack(spacing: 10) {
            Capsule()
                .fill(event.color.swatch)
                .frame(width: 3, height: 26)
            VStack(alignment: .trailing, spacing: 1) {
                Text(times.top)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                if let bottom = times.bottom {
                    Text(bottom)
                        .font(.system(size: 10))
                        .foregroundStyle(NotchStyle.tertiary)
                }
            }
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: 50, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .strikethrough(event.canceled)
                if !detail.isEmpty {
                    Text(detail)
                        .font(NotchStyle.smallFont)
                        .foregroundStyle(NotchStyle.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if event.isAttendable && event.end <= model.now {
                Text("Earlier")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(NotchStyle.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.1), in: Capsule())
            } else if !live, let next = model.timeline.next, CalendarAlerts.sameMeeting(next, event) || next.id == event.id {
                Text("Next")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(Capsule().stroke(Color.white.opacity(0.5), lineWidth: 1))
            }
            if live {
                Text("Now")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green, in: Capsule())
            }
            if let link = event.link, !event.canceled, event.end > model.now {
                CalendarPillButton(title: "Join", symbol: "video.fill") { model.actions.join(event) }
                    .help("Join on \(link.service.name)")
            }
        }
        .padding(.vertical, 3)
        .opacity(event.declined || event.canceled ? 0.45 : (event.isAttendable && event.end <= model.now ? 0.6 : 1))
    }
}

/// A small month to jump the agenda to any day. Dots mark days with events.
private struct CalendarMonthGrid: View {
    @ObservedObject var model: CalendarModel

    var body: some View {
        let calendar = model.calendar
        let days = CalendarMonthLayout.days(month: model.month, calendar: calendar)
        let month = calendar.component(.month, from: model.month)
        VStack(spacing: 3) {
            HStack(spacing: 2) {
                Text(model.month.formatted(.dateTime.month(.wide).year()))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !model.isAtToday {
                    Button { model.goToday() } label: {
                        Text("Today")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.14), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                arrow("chevron.left") { model.moveMonth(-1) }
                arrow("chevron.right") { model.moveMonth(1) }
            }
            .frame(height: 20)

            HStack(spacing: 0) {
                ForEach(Array(CalendarMonthLayout.weekdaySymbols(calendar: calendar).enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(NotchStyle.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }

            if days.count == 42 {
                VStack(spacing: 1) {
                    ForEach(0..<6, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(days[(row * 7)..<(row * 7 + 7)], id: \.self) { day in
                                CalendarDayCell(
                                    number: calendar.component(.day, from: day),
                                    inMonth: calendar.component(.month, from: day) == month,
                                    isToday: day == model.today,
                                    selected: day == model.selectedDay,
                                    busy: model.busyDays.contains(day)) { model.pick(day) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func arrow(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(NotchStyle.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct CalendarDayCell: View {
    let number: Int
    let inMonth: Bool
    let isToday: Bool
    let selected: Bool
    let busy: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            VStack(spacing: 1) {
                Text("\(number)")
                    .font(.system(size: 10.5, weight: isToday ? .bold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(isToday ? Color.black : (inMonth ? Color.white : Color.white.opacity(0.28)))
                    .frame(width: 18, height: 18)
                    .background {
                        if isToday {
                            Circle().fill(Color.white)
                        } else if selected {
                            Circle().stroke(Color.white.opacity(0.7), lineWidth: 1)
                        }
                    }
                Circle()
                    .fill(busy ? Color.white.opacity(inMonth ? 0.6 : 0.25) : Color.clear)
                    .frame(width: 3, height: 3)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared

/// Says why there's nothing to show (off, not yet allowed, denied) with the one button
/// that fixes it.
private struct CalendarAccessNotice: View {
    @ObservedObject var model: CalendarModel
    let compact: Bool

    var body: some View {
        let info = details
        VStack(alignment: compact ? .leading : .center, spacing: compact ? 4 : 6) {
            Image(systemName: info.symbol)
                .font(.system(size: compact ? 17 : 24, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            Text(info.title)
                .font(.system(size: compact ? 13 : 15, weight: .semibold))
                .foregroundStyle(.white)
            Text(compact ? info.short : info.long)
                .font(compact ? NotchStyle.smallFont : NotchStyle.bodyFont)
                .foregroundStyle(NotchStyle.secondary)
                .multilineTextAlignment(compact ? .leading : .center)
                .fixedSize(horizontal: false, vertical: true)
            CalendarPillButton(title: info.button, action: info.action)
                .padding(.top, compact ? 4 : 6)
        }
        .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity, alignment: compact ? .leading : .center)
    }

    private var details: (symbol: String, title: String, short: String, long: String, button: String,
                          action: @MainActor () -> Void) {
        let actions = model.actions
        switch model.access {
        case .off:
            return ("calendar", "Calendar is off", "Turn it on for events and meeting alerts.",
                    "Turn it on to see your next events and get an alert before meetings.",
                    "Turn On", actions.enable)
        case .notDetermined:
            return ("calendar.badge.clock", "Calendar access", "Allow access to see your events.",
                    "Dynamic Notch reads your calendars to list events and alert you before meetings.",
                    "Allow Access", actions.requestAccess)
        case .denied, .granted:
            return ("calendar.badge.exclamationmark", "No calendar access",
                    "Allow it in Privacy & Security, Calendars.",
                    "Allow Dynamic Notch full access in System Settings, Privacy & Security, Calendars.",
                    "Open Settings", actions.openPrivacySettings)
        }
    }
}

private struct CalendarPillButton: View {
    let title: String
    var symbol: String? = nil
    var fill = false
    let action: @MainActor () -> Void

    var body: some View {
        Button { action() } label: {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: fill ? .infinity : nil)
            .background(Color.white, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
