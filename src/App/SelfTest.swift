import AppKit

/// `--selftest`: checks the parts that don't need a screen. Prints one line per check.
@MainActor
enum SelfTest {
    static func run() -> Bool {
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print((ok ? "ok    " : "FAIL  ") + name)
            if !ok { failures += 1 }
        }

        // Geometry: this MacBook Air's notch is 179 × 32 pt on a 1470 × 956 pt screen.
        let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let g = NotchGeometry.compute(screenFrame: screen, safeTop: 32, leftWidth: 645.5, rightWidth: 645.5)
        check(g?.notchSize == CGSize(width: 179, height: 32), "notch size comes from the menu bar areas")
        check(g?.centerX == 735, "notch is centered")
        check(g?.notchRect.maxY == screen.maxY, "notch touches the top edge")
        check(NotchGeometry.compute(screenFrame: screen, safeTop: 0, leftWidth: 645.5, rightWidth: 645.5) == nil,
              "no safe area means no notch")
        check(NotchGeometry.compute(screenFrame: screen, safeTop: 32, leftWidth: nil, rightWidth: nil) == nil,
              "no menu bar areas means no notch")
        check(NotchGeometry.compute(screenFrame: screen, safeTop: 32, leftWidth: 735, rightWidth: 735) == nil,
              "a zero-width notch is rejected")
        let offset = CGRect(x: -1512, y: 200, width: 1512, height: 982)
        check(NotchGeometry.compute(screenFrame: offset, safeTop: 38, leftWidth: 662, rightWidth: 662)?.notchRect
              == CGRect(x: -850, y: 1144, width: 188, height: 38), "works on a screen left of and above the main one")

        // Metrics.
        let m = NotchMetrics(notch: CGSize(width: 179, height: 32), panel: CGSize(width: 806, height: 250))
        let modes: [NotchMode] = [.idle, .hover, .compact, .peek, .open]
        check(m.body(.idle) == m.notch && m.frame(.idle) == m.notch, "the idle shape is exactly the notch")
        check(m.frame(.open).width == 806, "the open shape matches the panel width")
        check(m.body(.peek).width == m.body(.compact).width, "peeking adds no menu bar width beyond compact")
        for mode in modes {
            check(m.window.width >= m.frame(mode).width + 2 * NotchMetrics.shadowMargin - 0.001
                  && m.window.height >= m.frame(mode).height, "the window holds \(mode)")
        }
        let idleHover = m.hoverRect(.idle, centerX: 735, top: 956)
        check(idleHover.minY >= 956 - 33, "an idle notch reacts only in the menu bar strip")
        for mode in modes.dropFirst() {
            check(m.hoverRect(mode, centerX: 735, top: 956).contains(idleHover),
                  "\(mode) hover area covers the idle one (no flicker)")
        }
        for mode in modes {
            check(m.hoverRect(mode, centerX: 735, top: 956).contains(m.captureRect(mode, centerX: 735, top: 956)),
                  "\(mode) takes clicks only where it counts as hovered")
            check(NotchMetrics.pointerIn(m.captureRect(mode, centerX: 735, top: 956), CGPoint(x: 735, y: 956)),
                  "\(mode) takes a click on the screen's top pixel row")
        }
        check(m.captureRect(.idle, centerX: 735, top: 956) == CGRect(x: 645.5, y: 924, width: 179, height: 32),
              "an idle notch takes clicks only inside the cutout")
        check(!NotchMetrics.pointerIn(m.captureRect(.idle, centerX: 735, top: 956), CGPoint(x: 735, y: 924)),
              "the row just below the notch is outside it")

        // Panel size fits the tabs and the screen.
        if let g {
            var narrow = Config()
            narrow.panelWidth = 480
            let fitted = NotchMetrics.make(geometry: g, config: narrow, tabCount: NotchTab.allCases.count)
            check(fitted.panel.width >= 567, "a narrow panel still fits 5 tab icons on each side of the notch")
            check(NotchMetrics.make(geometry: g, config: Config(), tabCount: 9).panel == CGSize(width: 806, height: 250),
                  "the default panel size is kept")
        }
        var huge = Config()
        huge.panelWidth = 1400
        huge.panelHeight = 700
        let small = CGRect(x: 0, y: 0, width: 1024, height: 665)
        if let gs = NotchGeometry.compute(screenFrame: small, safeTop: 32, leftWidth: 422.5, rightWidth: 422.5) {
            let fitted = NotchMetrics.make(geometry: gs, config: huge, tabCount: 9)
            check(fitted.window.width <= small.width && fitted.window.height <= small.height,
                  "a big panel shrinks to fit a scaled-up screen")
        } else {
            check(false, "small screen geometry")
        }

        // Activities.
        let c = ActivityCenter()
        let t0 = ContinuousClock.now
        func at(_ s: Double) -> ContinuousClock.Instant { t0.advanced(by: .seconds(s)) }
        c.post(Activity(id: "np", priority: .nowPlaying, symbol: "music.note", title: "Song"), now: at(0))
        c.post(Activity(id: "perm", priority: .permission, symbol: "hand.raised", title: "Allow?"), now: at(1))
        check(c.top?.id == "perm", "a permission request beats now playing")
        c.post(Activity(id: "caps", priority: .transient, symbol: "capslock", title: "Caps", duration: 2), now: at(2))
        c.post(Activity(id: "cam", priority: .privacy, symbol: "video", title: "Camera"), now: at(3))
        c.remove(id: "perm")
        check(c.top?.id == "cam", "camera comes next")
        c.post(Activity(id: "mic", priority: .privacy, symbol: "mic", title: "Mic"), now: at(3.5))
        check(c.top?.id == "mic", "the newest wins a tie")
        c.post(Activity(id: "np", priority: .nowPlaying, symbol: "music.note", title: "Song 2"), now: at(3.6))
        check(c.activities.filter { $0.id == "np" }.count == 1, "posting the same id replaces it")
        c.pruneExpired(now: at(3.9))
        check(c.activities.contains { $0.id == "caps" }, "a transient stays until its time is up")
        c.pruneExpired(now: at(4.1))
        check(!c.activities.contains { $0.id == "caps" }, "a transient goes after 2 s")
        c.post(Activity(id: "meet", priority: .alert, symbol: "calendar", title: "Meeting", urgent: true), now: at(5))
        check(c.top?.id == "mic" && c.topUrgent?.id == "meet" && c.hasUrgent,
              "an urgent alert is found even under a more important activity")
        c.removeAll()
        check(c.top == nil && !c.hasUrgent, "clearing leaves nothing")

        // Config.
        let partial = #"{"collapseDelay": 0.4, "panelWidth": 99999, "tabs": ["shelf", "bogus", "home", "shelf"], "hiddenTabs": ["stocks", "prompter"]}"#
        let cfg = try? JSONDecoder().decode(Config.self, from: Data(partial.utf8))
        check(cfg?.collapseDelay == 0.4, "settings keep given values")
        check(cfg?.panelHeight == 250 && cfg?.hoverDelay == 0.15, "settings fill in missing values")
        check(cfg?.panelWidth == 1400, "settings clamp the panel width")
        check(cfg?.tabs.prefix(2) == [.shelf, .home] && cfg?.tabs.count == NotchTab.allCases.count,
              "tab order kept, unknown and repeated names dropped, missing tabs appended")
        check(cfg?.hiddenTabs == [.prompter], "unknown hidden tabs are ignored")
        check((try? JSONDecoder().decode(Config.self, from: Data(#"{"hiddenCalendars": ["a", "b"]}"#.utf8)))?.hiddenCalendars == ["a", "b"],
              "hidden calendars are read")
        check((try? JSONDecoder().decode(Config.self, from: Data("{}".utf8))) == Config(), "an empty file means defaults")
        check((try? JSONDecoder().decode(Config.self, from: Data(#"{"collapseDelay": "soon"}"#.utf8)))?.collapseDelay == 0.1,
              "a wrong type falls back to the default")
        if let data = try? JSONEncoder().encode(Config()) {
            check((try? JSONDecoder().decode(Config.self, from: data)) == Config(), "settings survive a save and load")
        } else {
            check(false, "settings encode")
        }
        check(Config.parse(Data(#"{"collapseDelay": 0.4,"#.utf8)) == .unreadable, "a syntax error is reported, not read as defaults")
        check(Config.parse(Data("[]".utf8)) == .unreadable, "a file that isn't an object is reported")
        check(Config.parse(Data("{}".utf8)) == .ok(Config()), "a readable file is read")
        check(Config.read(from: URL(fileURLWithPath: "/nonexistent/dynamic-notch/config.json")) == .missing,
              "a missing file is told apart from a broken one")

        // Edit keys in the panels' text fields.
        check(EditKeys.action(.command, "v") == #selector(NSText.paste(_:)), "⌘V pastes in a text field")
        check(EditKeys.action([.command, .capsLock], "A") == #selector(NSText.selectAll(_:)), "⌘A works with Caps Lock on")
        check(EditKeys.action([.command, .shift], "Z") == EditKeys.redo, "⇧⌘Z redoes")
        check(EditKeys.action([.command, .shift], "v") == nil && EditKeys.action([.command, .option], "c") == nil,
              "other modifier combinations are left alone")

        // Model.
        var hidden = Config()
        hidden.hiddenTabs = NotchTab.allCases
        let model = NotchModel(activities: ActivityCenter(), config: hidden)
        check(model.visibleTabs == [.settings], "hiding every tab still leaves Settings")
        model.config = Config()
        model.tab = .terminal
        model.config.hiddenTabs = [.terminal]
        check(model.currentTab == .home, "a hidden selected tab falls back to the first visible one")
        model.open()
        check(!model.isOpen, "Open does nothing while there's no notch (lid closed)")
        model.geometry = g
        check(model.mode == .idle, "starts idle")
        model.activities.post(TestActivities.all[0].activity)
        check(model.mode == .compact, "an activity makes it compact")
        model.open()
        check(model.mode == .open, "opens")
        model.close()
        check(model.mode == .compact, "closing goes back to compact")
        model.pointerMoved(inside: true)
        check(!model.hovering, "hover waits for the pointer to rest")
        model.pointerMoved(inside: false)
        model.setHoveringForSnapshot(true)
        check(model.mode == .peek, "hovering an activity peeks")
        model.setHoveringForSnapshot(false)
        model.activities.removeAll()
        model.activities.post(TestActivities.sample("test.camera")!)
        model.activities.post(TestActivities.sample("test.meeting")!)
        model.inFullscreenSpace = true
        check(model.shownActivity?.id == "test.meeting", "a fullscreen Space shows the urgent meeting, not the camera")
        model.inFullscreenSpace = false
        check(model.shownActivity?.id == "test.camera", "elsewhere the camera comes first")

        // Leave-to-close: opening from the menu while the pointer is on its way out doesn't arm it.
        let lm = NotchModel(activities: ActivityCenter(), config: Config())
        lm.geometry = g
        lm.config.hoverDelay = 0
        lm.config.collapseDelay = 60
        lm.pointerMoved(inside: true)
        check(lm.hovering, "with no hover delay, hover starts at once")
        lm.pointerMoved(inside: false)
        lm.open()
        check(lm.isOpen && !lm.closesOnLeave, "opening while a leave is pending doesn't arm leave-to-close")
        lm.pointerMoved(inside: true)
        check(lm.closesOnLeave, "coming back onto the open panel arms it")

        // An activity that appears while the pointer already rests on the notch waits too.
        let hm = NotchModel(activities: ActivityCenter(), config: Config())
        hm.geometry = g
        hm.config.hoverDelay = 0
        hm.config.collapseDelay = 60
        hm.pointerMoved(inside: true)
        let h0 = ContinuousClock.now
        func after(_ s: Double) -> ContinuousClock.Instant { h0.advanced(by: .seconds(s)) }
        hm.activities.post(Activity(id: "late", priority: .transient, symbol: "capslock", title: "Caps",
                                    duration: 0.5), now: h0)
        hm.pointerMoved(inside: true)
        hm.activities.pruneExpired(now: after(1))
        check(hm.activities.activity(id: "late") != nil, "an activity shown while hovering doesn't expire under the pointer")
        hm.activities.resumeExpiry(now: after(1))
        hm.activities.pruneExpired(now: after(3.9))
        check(hm.activities.activity(id: "late") != nil, "after the pointer leaves it stays 3 s more")
        hm.activities.pruneExpired(now: after(4.1))
        check(hm.activities.activity(id: "late") == nil, "then it goes")

        // Features.
        FeatureRegistry.selfTests(check)

        print(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")
        return failures == 0
    }
}
