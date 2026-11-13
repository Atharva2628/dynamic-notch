import SwiftUI

/// What the views can ask for. The feature supplies these; snapshots use the no-ops.
struct AgentsActions {
    var open: @MainActor (String) -> Void = { _ in }                   // bring a session's window forward
    var answer: @MainActor (Int, AgentsAnswer) -> Void = { _, _ in }   // a permission request's buttons
    var refreshUsage: @MainActor () -> Void = {}
    var signIn: @MainActor () -> Void = {}                             // signs the claude command in, in a terminal tab
    var setKeepAwake: @MainActor (Bool) -> Void = { _ in }
    var showTab: @MainActor () -> Void = {}                            // the Home card opens the Agents tab
}

/// The Agents tab: permission requests and sessions on the left with the API-price table
/// under them, usage limits and Agent Away on the right.
struct AgentsTabView: View {
    @ObservedObject var store: AgentsStore
    let actions: AgentsActions
    var scrolls = true          // false in snapshots: ImageRenderer can't draw a scroll view

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                AgentsSessionsColumn(store: store, actions: actions, scrolls: scrolls)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if let cost = store.cost {
                    AgentsCostLine(report: cost)
                }
            }
            AgentsSideColumn(store: store, actions: actions)
                .frame(width: 330)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .foregroundStyle(.white)
    }
}

private struct AgentsSessionsColumn: View {
    @ObservedObject var store: AgentsStore
    let actions: AgentsActions
    let scrolls: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if store.queue.items.isEmpty && store.book.sessions.isEmpty {
                empty
            } else if scrolls {
                ScrollView(.vertical, showsIndicators: false) { list }
            } else {
                list
                Spacer(minLength: 0)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Claude Code").font(NotchStyle.titleFont)
            Text(counts).font(NotchStyle.smallFont).foregroundStyle(NotchStyle.secondary)
            Spacer(minLength: 0)
            if !store.approvals {
                Text("Approvals off").font(NotchStyle.smallFont).foregroundStyle(NotchStyle.tertiary)
            }
        }
        .frame(height: 16)
    }

    private var counts: String {
        let b = store.book
        var parts: [String] = []
        if b.count(.working) > 0 { parts.append("\(b.count(.working)) working") }
        if b.count(.waiting) > 0 { parts.append("\(b.count(.waiting)) waiting") }
        if b.count(.idle) > 0 { parts.append("\(b.count(.idle)) idle") }
        return parts.joined(separator: " · ")
    }

    private var list: some View {
        VStack(spacing: 6) {
            ForEach(store.queue.items) { request in
                AgentsRequestCard(request: request, actions: actions, fullText: scrolls)
            }
            ForEach(store.book.ordered) { session in
                AgentsSessionRow(session: session, cost: store.cost?.sessions[session.id]) { actions.open(session.id) }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(NotchStyle.secondary)
            Text("No Claude Code sessions").font(NotchStyle.bodyFont)
            Text("They show up here once Claude Code runs with the notch hooks.")
                .font(NotchStyle.smallFont)
                .foregroundStyle(NotchStyle.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One session: state, project, current tool and age. Clicking brings its window forward.
private struct AgentsSessionRow: View {
    let session: AgentsSession
    var cost: Double? = nil         // the session's tokens at API prices
    let open: () -> Void
    private let hovering = State(initialValue: false)   // @State is a macro, unavailable without Xcode

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                AgentsStateChip(state: session.state)
                Text(session.project)
                    .font(NotchStyle.titleFont)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(session.tool ?? placeholder)
                    .font(NotchStyle.monoFont)
                    .foregroundStyle(session.tool == nil ? NotchStyle.tertiary : NotchStyle.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if let cost, cost >= 0.01 {
                    Text(AgentsCostFormat.dollars(cost))
                        .font(NotchStyle.monoFont)
                        .foregroundStyle(NotchStyle.tertiary)
                        .help("This session's tokens at API prices")
                }
                AgentsClockText(since: session.started, step: 10)
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hovering.wrappedValue ? Color.white : NotchStyle.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(hovering.wrappedValue ? NotchStyle.cardHover : NotchStyle.card,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering.wrappedValue = $0 }
        .help("\(session.state.title) in \(session.cwd). Click to bring its window to the front.")
    }

    private var placeholder: String {
        switch session.state {
        case .working: "Thinking…"
        case .waiting: "Needs you"
        case .idle: "Ready"
        }
    }
}

private struct AgentsStateChip: View {
    let state: AgentsSessionState

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(color.opacity(0.16), in: Capsule())
        .frame(width: 70, alignment: .leading)
    }

    private var title: String {
        switch state {
        case .working: "Working"
        case .waiting: "Waiting"
        case .idle: "Idle"
        }
    }

    private var color: Color {
        switch state {
        case .working: Color(red: 0.45, green: 0.75, blue: 1)
        case .waiting: .orange
        case .idle: Color.white.opacity(0.55)
        }
    }
}

/// A permission request with the whole command and the same buttons as the notch's peek.
private struct AgentsRequestCard: View {
    let request: AgentsPermissionRequest
    let actions: AgentsActions
    let fullText: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(AgentsToolText.verb(tool: request.tool)).font(NotchStyle.titleFont)
                Text(request.project)
                    .font(NotchStyle.smallFont)
                    .foregroundStyle(NotchStyle.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                AgentsClockText(since: request.received, step: 1)
            }
            Text(request.detail)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(fullText ? nil : 3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let note = request.note {
                Text(note)
                    .font(NotchStyle.smallFont)
                    .foregroundStyle(NotchStyle.tertiary)
                    .lineLimit(1)
            }
            // What the second button allows, before you click it.
            if let scope = request.alwaysScope {
                Text(scope.text)
                    .font(NotchStyle.smallFont)
                    .foregroundStyle(NotchStyle.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(scope.text)
            }
            HStack(spacing: 6) {
                AgentsPillButton(title: "Allow", style: .primary) { actions.answer(request.id, .allow) }
                if let scope = request.alwaysScope {
                    AgentsPillButton(title: scope.button) { actions.answer(request.id, .always) }
                }
                AgentsPillButton(title: "Deny", style: .destructive) { actions.answer(request.id, .deny) }
                AgentsPillButton(title: "Open") { actions.answer(request.id, .open) }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1))
    }
}

/// A capsule button like the ones in the notch's peek.
private struct AgentsPillButton: View {
    enum Style { case normal, primary, destructive }
    let title: String
    var style: Style = .normal
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(height: 24)
                .foregroundStyle(style == .primary ? Color.black : Color.white)
                .background(background, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var background: Color {
        switch style {
        case .primary: .white
        case .destructive: .red.opacity(0.8)
        case .normal: .white.opacity(0.16)
        }
    }
}

/// Time since `since`, redrawn every `step` seconds while it is on screen.
private struct AgentsClockText: View {
    let since: Date
    let step: TimeInterval

    var body: some View {
        TimelineView(.periodic(from: .now, by: step)) { context in
            Text(AgentsFormat.duration(context.date.timeIntervalSince(since)))
                .font(NotchStyle.smallFont)
                .monospacedDigit()
                .foregroundStyle(NotchStyle.tertiary)
        }
    }
}

private struct AgentsSideColumn: View {
    @ObservedObject var store: AgentsStore
    let actions: AgentsActions

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if store.usage.enabled {
                AgentsUsageSummary(usage: store.usage, refresh: actions.refreshUsage, signIn: actions.signIn)
            } else {
                Text("Usage limits are off")
                    .font(NotchStyle.smallFont)
                    .foregroundStyle(NotchStyle.tertiary)
            }
            Spacer(minLength: 0)
            if let away = store.away {
                AgentsAwayRow(status: away, setKeepAwake: actions.setKeepAwake)
            }
        }
    }
}

/// Two rings with reset countdowns, model limits below them, and how fresh it all is.
private struct AgentsUsageSummary: View {
    let usage: AgentsUsageState
    let refresh: () -> Void
    var signIn: () -> Void = {}

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let stale = usage.isStale(now: now)
            VStack(alignment: .leading, spacing: 4) {
                // Fable gets the first ring; the closest other model limit gets a third.
                let model = usage.snapshot?.otherScoped.max { ($0.percent(at: now) ?? -1) < ($1.percent(at: now) ?? -1) }
                HStack(alignment: .top, spacing: 4) {
                    AgentsRingTile(window: usage.snapshot?.fable, title: "Fable", stale: stale, now: now)
                    AgentsRingTile(window: usage.snapshot?.weekly, title: "Weekly", stale: stale, now: now)
                    if let model {
                        AgentsRingTile(window: model, title: model.title, stale: stale, now: now)
                    }
                }
                .frame(maxWidth: .infinity)
                Button(action: refresh) {
                    Text(usage.status(now: now))
                        .font(.system(size: 11))
                        .foregroundStyle(usage.problem?.isError == true ? Color.orange : NotchStyle.tertiary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Check now")
                if usage.needsSignIn {
                    AgentsSignInButton(action: signIn)
                }
            }
        }
    }
}

/// Opens a terminal tab that signs the `claude` command in, which is where the limits come from.
private struct AgentsSignInButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Sign in", systemImage: "person.crop.circle.badge.checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.white, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Runs claude auth login in a terminal tab; it opens your browser to sign in")
    }
}

/// A ring with its title and time to reset.
private struct AgentsRingTile: View {
    let window: AgentsUsageWindow?
    let title: String
    let stale: Bool
    let now: Date
    var size: CGFloat = 46

    var body: some View {
        VStack(spacing: 3) {
            AgentsRing(percent: window?.percent(at: now), size: size, stale: stale)
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(window.map { AgentsFormat.reset($0.resetsAt, now: now).replacingOccurrences(of: "resets ", with: "") } ?? "–")
                .font(.system(size: 11))
                .foregroundStyle(NotchStyle.tertiary)
                .lineLimit(1)
        }
        .frame(width: 106)
    }
}

/// A usage ring: white below 80%, orange from 80%, red from 95%.
struct AgentsRing: View {
    let percent: Double?
    let size: CGFloat
    var stale = false

    var body: some View {
        let line = max(3, size * 0.1)
        ZStack {
            Circle().stroke(Color.white.opacity(0.14), lineWidth: line)
            if let p = percent {
                Circle()
                    .trim(from: 0, to: max(0.005, min(1, p / 100)))
                    .stroke(Self.color(p), style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(percent.map { "\(Int($0.rounded()))%" } ?? "–")
                .font(.system(size: size * 0.26, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .padding(line / 2)
        .frame(width: size, height: size)
        .opacity(stale ? 0.55 : 1)
    }

    static func color(_ p: Double) -> Color {
        p >= 95 ? .red : p >= 80 ? .orange : Color(red: 0.55, green: 0.8, blue: 1)
    }
}

/// Agent Away's state, with its keep-awake switch when its app is running.
private struct AgentsAwayRow: View {
    let status: AgentsAwayStatus
    let setKeepAwake: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: status.keepAwake ? "sun.max.fill" : "moon.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(status.keepAwake ? Color.yellow : NotchStyle.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Agent Away").font(.system(size: 11, weight: .semibold))
                Text(status.line)
                    .font(.system(size: 10))
                    .foregroundStyle(status.heat == nil ? NotchStyle.secondary : Color.orange)
                    .lineLimit(1)
                    .help(status.line)
            }
            Spacer(minLength: 4)
            if status.running {
                Button { setKeepAwake(!status.keepAwake) } label: {
                    ZStack(alignment: status.keepAwake ? .trailing : .leading) {
                        Capsule().fill(status.keepAwake ? Color.green.opacity(0.85) : Color.white.opacity(0.2))
                        Circle().fill(.white).padding(2)
                    }
                    .frame(width: 30, height: 18)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(status.keepAwake ? "Turn keep awake off (also turns off ask first)"
                                       : "Keep the Mac awake for Claude, even with the lid closed")
            }
        }
        .padding(8)
        .background(NotchStyle.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// The Home card: how many sessions work or wait, and the two limits.
struct AgentsHomeCard: View {
    @ObservedObject var store: AgentsStore
    let actions: AgentsActions

    var body: some View {
        let working = store.book.count(.working)
        let waiting = store.book.count(.waiting)
        let requests = store.queue.items.count
        let stale = store.usage.isStale(now: Date())
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.8, green: 0.6, blue: 1))
                Text("Claude").font(NotchStyle.titleFont)
                Spacer(minLength: 0)
                if requests > 0 {
                    Label("\(requests)", systemImage: "hand.raised.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 6)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(working)").font(.system(size: 24, weight: .semibold)).monospacedDigit()
                Text("working").font(NotchStyle.smallFont).foregroundStyle(NotchStyle.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(waiting)")
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(waiting > 0 ? Color.orange : Color.white)
                Text("waiting for you").font(NotchStyle.smallFont).foregroundStyle(NotchStyle.secondary)
            }
            if let cost = store.cost, !cost.scanning {
                Text("\(AgentsCostFormat.dollars(cost.today)) · \(AgentsCostFormat.tokens(cost.day.tokens)) tokens today")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(NotchStyle.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.top, 3)
            }
            Spacer(minLength: 6)
            if store.usage.enabled {
                HStack(spacing: 12) {
                    mini(store.usage.snapshot?.fable, "Fable", stale)
                    mini(store.usage.snapshot?.weekly, "week", stale)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { actions.showTab() }
    }

    private func mini(_ w: AgentsUsageWindow?, _ label: String, _ stale: Bool) -> some View {
        VStack(spacing: 2) {
            AgentsRing(percent: w?.percent(at: Date()), size: 36, stale: stale)
            Text(label).font(.system(size: 10)).foregroundStyle(NotchStyle.tertiary)
        }
    }
}

/// The menu bar dropdown's Usage tab: big rings, reset times, model limits.
struct AgentsUsagePanel: View {
    @ObservedObject var store: AgentsStore
    let actions: AgentsActions

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let usage = store.usage
            let stale = usage.isStale(now: now)
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    Text("Claude usage").font(.system(size: 15, weight: .semibold))
                    Spacer(minLength: 0)
                    if usage.enabled {
                        Text(usage.status(now: now))
                            .font(NotchStyle.smallFont)
                            .foregroundStyle(usage.problem?.isError == true ? Color.orange : NotchStyle.tertiary)
                        Button(action: actions.refreshUsage) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .help("Check now")
                        if usage.needsSignIn {
                            AgentsSignInButton(action: actions.signIn)
                        }
                    }
                }
                if !usage.enabled {
                    Text("Usage limits are off. Set \"usageSource\" to \"keychain\" in config.json to show them.")
                        .font(NotchStyle.bodyFont)
                        .foregroundStyle(NotchStyle.secondary)
                } else {
                    HStack(alignment: .top, spacing: 32) {
                        bigTile(usage.snapshot?.fable, "Fable limit", stale, now)
                        bigTile(usage.snapshot?.weekly, "Weekly limit", stale, now)
                    }
                    if let scoped = usage.snapshot?.otherScoped, !scoped.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(scoped) { bar($0, stale, now) }
                        }
                    }
                }
                if let cost = store.cost {
                    AgentsCostPanel(report: cost)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }

    private func bigTile(_ w: AgentsUsageWindow?, _ title: String, _ stale: Bool, _ now: Date) -> some View {
        HStack(spacing: 14) {
            AgentsRing(percent: w?.percent(at: now), size: 84, stale: stale)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(NotchStyle.titleFont)
                Text(w.map { AgentsFormat.reset($0.resetsAt, now: now) } ?? "No data yet")
                    .font(NotchStyle.bodyFont)
                    .foregroundStyle(NotchStyle.secondary)
                if let at = w?.resetsAt, at > now {
                    Text(Self.clock(at, now: now)).font(NotchStyle.smallFont).foregroundStyle(NotchStyle.tertiary)
                }
            }
        }
    }

    private func bar(_ w: AgentsUsageWindow, _ stale: Bool, _ now: Date) -> some View {
        HStack(spacing: 10) {
            Text(w.title).font(NotchStyle.bodyFont).frame(width: 130, alignment: .leading).lineLimit(1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                if let p = w.percent(at: now) {
                    Capsule().fill(AgentsRing.color(p)).frame(width: max(4, 180 * p / 100))
                }
            }
            .frame(width: 180, height: 6)
            Text(w.percent(at: now).map { "\(Int($0.rounded()))%" } ?? "–").font(NotchStyle.bodyFont).monospacedDigit().frame(width: 40, alignment: .trailing)
            Text(AgentsFormat.reset(w.resetsAt, now: now)).font(NotchStyle.smallFont).foregroundStyle(NotchStyle.tertiary)
        }
        .opacity(stale ? 0.55 : 1)
    }

    /// "at 18:00" today, "Tue 11:00" on another day.
    private static func clock(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? "at " + date.formatted(.dateTime.hour().minute())
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// The spans the cost views show, shortest first.
enum AgentsCostSpans {
    static func list(_ r: AgentsCostReport) -> [(short: String, long: String, totals: AgentsCostTotals)] {
        [("5h", "Last 5 hours", r.fiveHour), ("today", "Today", r.day), ("7d", "Last 7 days", r.last7),
         ("30d", "Last 30 days", r.last30), ("all", "All time", r.all)]
    }

    /// "since Oct 11" for the all-time figure.
    static func since(_ r: AgentsCostReport) -> String {
        guard let first = r.firstDay else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: first) else { return "since \(first)" }
        return "since " + d.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// The Agents tab's cost block: dollars at API prices and tokens for 5 hours, today, 7 and
/// 30 days, and all time.
private struct AgentsCostLine: View {
    let report: AgentsCostReport

    var body: some View {
        if report.scanning {
            HStack(spacing: 6) {
                Text("API $").font(.system(size: 12, weight: .semibold)).foregroundStyle(NotchStyle.tertiary)
                Text("adding up your transcripts…").foregroundStyle(NotchStyle.secondary)
            }
            .font(.system(size: 14))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NotchStyle.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            let spans = AgentsCostSpans.list(report)
            Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 2) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    ForEach(spans, id: \.short) { s in
                        Text(s.short).foregroundStyle(NotchStyle.tertiary)
                    }
                }
                .font(.system(size: 12))
                GridRow {
                    Text("API $").font(.system(size: 12, weight: .semibold)).foregroundStyle(NotchStyle.tertiary)
                        .gridColumnAlignment(.leading)
                    ForEach(spans, id: \.short) { s in
                        Text(AgentsCostFormat.dollars(s.totals.cost, compact: true)).fontWeight(.semibold)
                    }
                }
                GridRow {
                    Text("tokens").font(.system(size: 12, weight: .semibold)).foregroundStyle(NotchStyle.tertiary)
                    ForEach(spans, id: \.short) { s in
                        Text(AgentsCostFormat.tokens(s.totals.tokens)).font(.system(size: 14)).foregroundStyle(NotchStyle.secondary)
                            .help(s.long + ": " + AgentsCostFormat.breakdown(s.totals))
                    }
                }
            }
            .font(.system(size: 16))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NotchStyle.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .help("What Claude Code's tokens would cost on the Claude API (your plan doesn't bill per token), "
                  + "read from this Mac's transcripts. All time is \(AgentsCostSpans.since(report)).")
        }
    }
}

/// The Usage dropdown's cost section: totals, the last 14 days, and the models behind them.
private struct AgentsCostPanel: View {
    let report: AgentsCostReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("At API prices").font(NotchStyle.titleFont)
                Text("what these tokens would cost on the Claude API; your plan doesn't bill per token")
                    .font(NotchStyle.smallFont)
                    .foregroundStyle(NotchStyle.tertiary)
                    .lineLimit(1)
            }
            if report.scanning {
                Text("Adding up your Claude Code transcripts… The first pass reads them all once.")
                    .font(NotchStyle.bodyFont)
                    .foregroundStyle(NotchStyle.secondary)
            } else {
                HStack(alignment: .top, spacing: 26) {
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                        ForEach(AgentsCostSpans.list(report), id: \.short) { s in
                            GridRow {
                                Text(AgentsCostFormat.dollars(s.totals.cost))
                                    .font(.system(size: 14, weight: .semibold))
                                    .monospacedDigit()
                                    .gridColumnAlignment(.trailing)
                                Text("\(AgentsCostFormat.tokens(s.totals.tokens)) tok")
                                    .font(NotchStyle.smallFont)
                                    .monospacedDigit()
                                    .foregroundStyle(NotchStyle.secondary)
                                    .gridColumnAlignment(.trailing)
                                    .help(AgentsCostFormat.breakdown(s.totals))
                                Text(s.short == "all" ? "All time, \(AgentsCostSpans.since(report))" : s.long)
                                    .font(NotchStyle.smallFont)
                                    .foregroundStyle(NotchStyle.tertiary)
                            }
                        }
                    }
                    .lineLimit(1)
                    .fixedSize()
                    chart
                    models
                }
                if report.unpriced > 0 {
                    Text("\(report.unpriced) responses from models without a known price aren't counted.")
                        .font(NotchStyle.smallFont)
                        .foregroundStyle(NotchStyle.tertiary)
                }
            }
        }
    }

    /// The last 14 days as bars, today on the right.
    private var chart: some View {
        let peak = max(report.days.map(\.cost).max() ?? 0, 0.01)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(report.days.enumerated()), id: \.element.id) { i, day in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(i == report.days.count - 1 ? Color.white : Color.white.opacity(0.35))
                        .frame(width: 9, height: max(2, 64 * day.cost / peak))
                        .help("\(day.id): \(AgentsCostFormat.dollars(day.cost))")
                }
            }
            .frame(height: 64, alignment: .bottom)
            Text("Last 14 days").font(.system(size: 9)).foregroundStyle(NotchStyle.tertiary)
        }
    }

    /// The models behind the last 30 days, most expensive first.
    private var models: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(report.models.prefix(4)) { m in
                HStack(spacing: 8) {
                    Text(AgentsCostFormat.modelName(m.id)).font(NotchStyle.bodyFont).frame(width: 82, alignment: .leading)
                    Text(AgentsCostFormat.dollars(m.cost)).font(NotchStyle.bodyFont).monospacedDigit().frame(width: 62, alignment: .trailing)
                    Text("\(AgentsCostFormat.tokens(m.tokens)) tok").font(NotchStyle.smallFont).foregroundStyle(NotchStyle.tertiary)
                }
                .lineLimit(1)
            }
        }
    }
}
