import Foundation

extension PrompterFeature {
    /// Pure checks: Notchy's settings, script text, word counts and timing, file names,
    /// scroll math and the session's clock, line mapping, and voice-follow word matching.
    /// Files go only to a temp folder that is removed afterwards.
    @MainActor
    static func selfTest(_ check: (Bool, String) -> Void) {
        // Notchy: "cuely.library" is JSON data; empty and repeated bodies are skipped.
        let library: [[String: Any]] = [
            ["id": "A70EE933", "title": "Script A", "body": "First sample script."],
            ["id": "B1", "title": "  ", "body": "Second script."],
            ["id": "C2", "title": "Copy", "body": "First sample script.\n"],
            ["id": "D3", "title": "Blank", "body": "   \n"],
        ]
        let defaults: [String: Any] = [
            "cuely.library": (try? JSONSerialization.data(withJSONObject: library)) ?? Data(),
            "cuely.script": "Fallback text",
            "settings.cuely.fontSize": 20.0,
        ]
        let plist = (try? PropertyListSerialization.data(fromPropertyList: defaults, format: .xml, options: 0)) ?? Data()
        let parsed = PrompterNotchy.scripts(fromPlist: plist)
        check(parsed == [PrompterImport(title: "Script A", body: "First sample script."),
                         PrompterImport(title: PrompterNotchy.fallbackTitle, body: "Second script.")],
              "prompter: Notchy's library parses, untitled scripts get a name, empty and repeated ones are skipped")
        check(PrompterNotchy.scripts(fromDefaults: ["cuely.script": "Only one"])
                == [PrompterImport(title: PrompterNotchy.fallbackTitle, body: "Only one")]
              && PrompterNotchy.scripts(fromDefaults: ["cuely.library": #"[{"id":"x","title":"S","body":"From a string"}]"#])
                == [PrompterImport(title: "S", body: "From a string")],
              "prompter: the single cuely.script is the fallback, and a library stored as a string works")
        check(PrompterNotchy.scripts(fromPlist: Data("not a plist".utf8)).isEmpty
              && PrompterNotchy.scripts(fromDefaults: ["cuely.library": Data("{broken".utf8)]).isEmpty,
              "prompter: broken Notchy settings import nothing")

        // Script text.
        let source = """
        ---
        tags: pitch
        ---
        # Opening ##
        <!-- note to self -->
        Hello, **world** — this is it.



        - first point
        > quoted line
        ***
        """
        let display = PrompterText.display(source)
        check(display == "Opening\nHello, **world** — this is it.\n\n• first point\nquoted line",
              "prompter: Markdown headings, lists, quotes, comments, front matter and rules are cleaned for reading")
        check(String(PrompterText.attributed("Say **this** and *that*").characters) == "Say this and that",
              "prompter: inline emphasis renders without its asterisks")
        check(PrompterText.wordCount(display) == 10 && PrompterText.wordCount("— • 2026 rock-solid") == 2,
              "prompter: words need a letter or digit; dashes and bullets don't count")
        check(PrompterText.display("---\nWelcome, everyone.\n---\nPart two") == "Welcome, everyone.\n\nPart two"
              && PrompterText.display("---\ntitle: Pitch\n---\nHello") == "Hello",
              "prompter: only real front matter is dropped; a script opening with a rule keeps its first section")

        // Timing.
        check(PrompterText.duration(words: 150, wordsPerMinute: 150) == 60
              && PrompterText.clock(125) == "2:05" && PrompterText.clock(3725) == "1:02:05" && PrompterText.clock(-3) == "0:00",
              "prompter: time at 150 wpm and its m:ss clock")
        check(PrompterScrollMath.timeLeft(words: 300, progress: 0.5, wordsPerMinute: 150) == 60,
              "prompter: time left counts only the words still ahead")

        // File names.
        check(PrompterText.fileName(for: "a/b:c\\d", taken: []) == "a-b-c-d.md"
              && PrompterText.fileName(for: "  ..hidden\nname.  ", taken: []) == "hidden name.md"
              && PrompterText.fileName(for: " \t ", taken: []) == "Untitled.md",
              "prompter: titles become safe file names: no separators, no leading dot, never empty")
        check(PrompterText.fileName(for: "Pitch", taken: ["pitch.md", "pitch 2.md"]) == "Pitch 3.md"
              && PrompterText.fileName(for: String(repeating: "x", count: 200), taken: []).count == 83,
              "prompter: clashing names are numbered (ignoring case) and long titles are cut to 80 characters")

        // Writing imports to a temp folder: repeats are skipped, clashing names numbered.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompter-selftest-\(UUID().uuidString)", isDirectory: true)
        let first = PrompterLibrary.write([PrompterImport(title: "Pitch", body: "One"), PrompterImport(title: "Pitch", body: "Two")], to: temp)
        let again = PrompterLibrary.write([PrompterImport(title: "Pitch", body: "One\n")], to: temp)
        let cache = PrompterScanCache()
        let scanned = PrompterLibrary.scan(temp, cache: cache)
        try? Data("One more\n".utf8).write(to: temp.appendingPathComponent("Pitch.md"))
        let rescanned = PrompterLibrary.scan(temp, cache: cache)
        check(first == 2 && again == 0 && Set(scanned.map(\.fileName)) == ["Pitch.md", "Pitch 2.md"]
              && scanned.allSatisfy { $0.words == 1 }
              && rescanned.first { $0.fileName == "Pitch.md" }?.words == 2 && cache.entries.count == 2,
              "prompter: imported scripts are written once, as <title>.md and <title> 2.md, read back, and read again once edited")
        check(PrompterLibrary.samePath(URL(fileURLWithPath: temp.path + "/"), URL(fileURLWithPath: temp.path + "/x/.."))
              && !PrompterLibrary.samePath(temp, temp.appendingPathComponent("other")),
              "prompter: the folder setting compares paths, so a trailing slash isn't a different folder")
        try? FileManager.default.removeItem(at: temp)

        // Scroll math.
        check(PrompterScrollMath.progress(position: 50, contentHeight: 200) == 0.25
              && PrompterScrollMath.progress(position: 500, contentHeight: 200) == 1
              && PrompterScrollMath.progress(position: 10, contentHeight: 0) == 0,
              "prompter: progress is the position over the text's height, clamped")
        check(PrompterScrollMath.advanced(10, speed: 40, dt: 0.5, contentHeight: 200) == 30
              && PrompterScrollMath.advanced(190, speed: 40, dt: 0.5, contentHeight: 200) == 200
              && PrompterScrollMath.rescaled(50, from: 200, to: 400) == 100,
              "prompter: steady scrolling stops at the end, and reflowing keeps the place")
        let eased = PrompterScrollMath.eased(0, toward: 100, dt: 1.0 / 60, contentHeight: 500)
        check(eased > 0 && eased < 100, "prompter: voice follow eases toward the spoken line instead of jumping")
        let notch = NotchGeometry.compute(screenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956),
                                          safeTop: 32, leftWidth: 645.5, rightWidth: 645.5)
        check(PrompterScrollMath.windowFrame(notch: notch, fallback: .zero, width: 420, height: 170)
                == CGRect(x: 525, y: 754, width: 420, height: 202)
              && PrompterScrollMath.windowFrame(notch: notch, fallback: .zero, width: 240, height: 170).width
                == NotchMetrics(notch: CGSize(width: 179, height: 32), panel: .zero).frame(.compact).width
              && PrompterScrollMath.windowFrame(notch: nil, fallback: CGRect(x: 0, y: 0, width: 1920, height: 1055),
                                               width: 420, height: 170) == CGRect(x: 750, y: 885, width: 420, height: 170),
              "prompter: the strip grows down from the notch as one shape, at least as wide as its ears, or hangs under the menu bar without one")

        // The session's clock: 3 s countdown, steady scroll, pauses, the end.
        let script = PrompterScript(url: URL(fileURLWithPath: "/tmp/x.md"), source: "One two three four.", modified: Date())
        let session = PrompterSession(script: script, speed: 50, fontSize: 20, wordsPerMinute: 150, followVoice: false)
        session.layoutChanged(width: 300, height: 100)
        session.tick(2.9)
        let stillCounting = session.phase == .countdown
        session.tick(0.2)
        session.tick(1)
        let afterOne = session.position
        session.hoverPaused = true
        session.tick(1)
        let held = session.position == afterOne && !session.needsFrames
        session.hoverPaused = false
        session.notchHeld = true
        session.tick(1)
        let covered = session.position == afterOne && !session.needsFrames
        session.notchHeld = false
        session.tick(0.5)
        session.tick(0.5)
        check(stillCounting && afterOne == 50 && held && covered && session.phase == .finished && session.progress == 1,
              "prompter: counts down 3 s, scrolls at the set speed, holds while hovered or under the notch, and finishes at the end")
        session.layoutChanged(width: 300, height: 200)
        check(session.position == 200, "prompter: a bigger font keeps the place in the script")
        check(!session.tick(PrompterSession.autoCloseAfter - 0.5) && session.tick(1),
              "prompter: the finished strip closes itself after a few seconds")

        // With voice follow, the strip waits for speech and the last word said finishes it.
        let voiced = PrompterSession(script: script, speed: 50, fontSize: 20, wordsPerMinute: 150, followVoice: true)
        voiced.layoutChanged(width: 300, height: 100)
        voiced.tick(3.1)
        let waits = voiced.phase == .running && voiced.position == 0 && !voiced.needsFrames
        let moved = voiced.heard("one two three four")
        for _ in 0..<240 { voiced.tick(1.0 / 60) }
        check(waits && moved && voiced.phase == .finished,
              "prompter: voice follow holds until words match, then eases to them; the last word ends the run")
        let sought = PrompterSession(script: script, speed: 50, fontSize: 20, wordsPerMinute: 150, followVoice: true)
        sought.layoutChanged(width: 300, height: 100)
        sought.seek(by: 40)
        let skippedCountdown = sought.phase == .running && sought.position == 40
        sought.seek(by: 500)
        let endedAtEnd = sought.phase == .finished
        sought.seek(by: -30)
        check(skippedCountdown && endedAtEnd && sought.phase == .running && sought.position == 70,
              "prompter: seeking skips the countdown, reaching the end finishes even with voice follow, and going back resumes")

        // Line map: lines go down the page and offsets find their line.
        let map = PrompterLineMap.make(text: "First paragraph.\n\nSecond paragraph that is long enough to wrap onto more lines here.",
                                       fontSize: 20, width: 180)
        check(map.lineStarts.count >= 4 && zip(map.lineTops, map.lineTops.dropFirst()).allSatisfy { $0 < $1 }
              && map.top(forOffset: 0) == 0 && map.top(forOffset: 20) > map.top(forOffset: 3)
              && map.offset(atY: map.top(forOffset: 20)) <= 20,
              "prompter: the line map places each offset on its laid-out line")

        // Voice follow: word matching.
        check(PrompterWordMatcher.normalize("Café,") == "cafe" && PrompterWordMatcher.normalize("Don't") == "dont"
              && PrompterWordMatcher.tokens("Hi—there, you’re").map(\.word) == ["hi", "there", "youre"]
              && PrompterWordMatcher.tokens("Hi—there").map(\.offset) == [0, 3],
              "prompter: words are normalized and keep their place in the text")
        var matcher = PrompterWordMatcher(text: "Hello everyone. Today I want to talk about the future of energy storage, and why it matters.")
        let opened = matcher.advance(heard: "hello everyone today I want")
        let afterWant = matcher.cursor
        check(opened && afterWant == 5, "prompter: speaking the opening words moves the cursor past them")
        check(!matcher.advance(heard: "completely different words here") && matcher.cursor == afterWant,
              "prompter: unrelated speech doesn't move the cursor")
        check(!matcher.advance(heard: "hello everyone") && matcher.cursor == afterWant,
              "prompter: repeating earlier words never moves it back")
        check(matcher.advance(heard: "the future of enerjy storage") && matcher.cursor == 13,
              "prompter: a slightly misheard word (enerjy) doesn't stop a match")
        check(PrompterWordMatcher.same("pitch", "pitching") && PrompterWordMatcher.same("energy", "enerjy")
              && !PrompterWordMatcher.same("cat", "cut") && !PrompterWordMatcher.same("the", "then"),
              "prompter: fuzzy matching allows stems and one-letter slips in long words only")
        matcher.seek(toOffset: 0)
        check(matcher.cursor == 0 && matcher.spokenOffset == 0, "prompter: seeking moves the cursor to the scrolled place")
    }
}
