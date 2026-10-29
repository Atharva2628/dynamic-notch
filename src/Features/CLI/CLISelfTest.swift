import SwiftUI

extension CLIFeature {
    /// Pure-logic checks: message validation, and what each command does to a private
    /// ActivityCenter and NotchModel.
    static func selfTest(_ check: (Bool, String) -> Void) {
        let known: Set<String> = ["bell.fill", "hammer.fill"]
        func parse(_ m: [String: Any]) -> Result<CLICommand, CLICommand.Failure> {
            CLICommand.parse(m) { known.contains($0) }
        }
        func error(_ m: [String: Any]) -> String? {
            if case .failure(let f) = parse(m) { return f.message }
            return nil
        }

        check(parse(["type": "cli", "cmd": "post", "text": "Build  done\n", "for": "5", "id": "build.1", "tint": "Green",
                     "icon": "hammer.fill", "title": "CI"])
              == .success(.post(id: "build.1", text: "Build done", title: "CI", icon: "hammer.fill", tint: .green, seconds: 5)),
              "cli: a full post parses, text on one line, tint in any case")
        let england = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"
        check(CLICommand.oneLine("\u{2764}\u{FE0F}\u{200D}\u{1F525} shipped") == "\u{2764}\u{FE0F}\u{200D}\u{1F525} shipped"
              && CLICommand.oneLine("\(england) won") == "\(england) won"
              && CLICommand.oneLine("a\n\tb\u{7}c\u{2028}d\u{85}e") == "a b c d e"
              && CLICommand.oneLine("\u{2067}abc\u{202E}def\u{2069}") == "abcdef",
              "cli: emoji joiners and flag tags stay; breaks and controls become spaces; bidi overrides go")
        check(parse(["cmd": "post", "text": "hi"]) == .success(.post(id: CLICommand.defaultID, text: "hi", title: nil,
                                                                      icon: nil, tint: nil, seconds: nil)),
              "cli: a bare post uses the default id")
        check(error(["cmd": "post", "text": "hi", "colour": "red"]) != nil && error(["cmd": "remove", "id": "a", "text": "x"]) != nil,
              "cli: unknown fields are refused")
        check(error(["cmd": "post", "text": "  \n\t"]) != nil && error(["cmd": "post"]) != nil
              && error(["cmd": "post", "text": 42]) != nil
              && error(["cmd": "post", "text": String(repeating: "x", count: CLICommand.maxText + 1)]) != nil,
              "cli: post text must be a non-empty string of sane length")
        check(error(["cmd": "post", "text": "x", "id": "../etc"]) != nil && error(["cmd": "post", "text": "x", "id": ""]) != nil
              && error(["cmd": "post", "text": "x", "id": String(repeating: "a", count: 65)]) != nil
              && error(["cmd": "post", "text": "x", "id": "é"]) != nil && error(["cmd": "remove", "id": "a-b_c.9"]) == nil,
              "cli: ids are 1 to 64 ASCII letters, digits, dots, dashes, underscores")
        check(error(["cmd": "post", "text": "x", "icon": "no.such.symbol"]) != nil
              && error(["cmd": "post", "text": "x", "icon": "Bell.Fill"]) != nil
              && error(["cmd": "post", "text": "x", "tint": "teal"]) != nil,
              "cli: unknown symbols and tints are refused")
        check(error(["cmd": "post", "text": "x", "for": "-1"]) != nil && error(["cmd": "post", "text": "x", "for": "1e3"]) != nil
              && error(["cmd": "post", "text": "x", "for": true]) != nil && error(["cmd": "post", "text": "x", "for": 90_000]) != nil
              && error(["cmd": "post", "text": "x", "for": "nan"]) != nil
              && parse(["cmd": "post", "text": "x", "for": 0.5]) == .success(.post(id: "message", text: "x", title: nil,
                                                                                  icon: nil, tint: nil, seconds: 0.5)),
              "cli: --for is a plain number from 0 to a day")
        check(parse(["cmd": "progress", "id": "render", "fraction": "40%"]) == .success(.progress(id: "render", fraction: 0.4, title: nil))
              && parse(["cmd": "progress", "id": "r", "fraction": 1]) == .success(.progress(id: "r", fraction: 1, title: nil))
              && error(["cmd": "progress", "id": "r", "fraction": "1.5"]) != nil
              && error(["cmd": "progress", "id": "r"]) != nil && error(["cmd": "progress", "fraction": "0.5"]) != nil,
              "cli: progress takes an id and a fraction (or a percentage) within 0...1")
        check(parse(["cmd": "open", "tab": "Clipboard"]) == .success(.open(tab: .clipboard))
              && parse(["cmd": "open"]) == .success(.open(tab: nil)) && error(["cmd": "open", "tab": "stocks"]) != nil,
              "cli: open takes a known tab name, or none")
        check(error(["cmd": "launch"]) != nil && error(["type": "cli"]) != nil && error(["cmd": 1]) != nil,
              "cli: unknown or missing commands are refused")

        // What the commands do.
        let activities = ActivityCenter()
        let model = NotchModel(activities: activities, config: Config())
        _ = apply(.post(id: "build", text: "Build done", title: nil, icon: nil, tint: .green, seconds: nil), activities: activities, model: model)
        let posted = activities.activity(id: "cli.build")
        check(posted?.priority == .info && posted?.title == "Build done" && posted?.duration == defaultSeconds
              && posted?.expands == true && posted?.tint == .green,
              "cli: a post becomes a peeking .info activity for 8 s by default")
        _ = apply(.post(id: "build", text: "Still here", title: "Watch", icon: nil, tint: nil, seconds: 0), activities: activities, model: model)
        let sticky = activities.activity(id: "cli.build")
        check(activities.activities.count == 1 && sticky?.duration == nil && sticky?.expands == false
              && sticky?.title == "Watch" && sticky?.subtitle == "Still here" && sticky?.actions.map(\.id) == ["dismiss"],
              "cli: the same id replaces it; --for 0 stays, collapsed, with a Dismiss button")
        activities.perform(activityID: "cli.build", actionID: "dismiss")
        check(activities.activity(id: "cli.build") == nil, "cli: Dismiss removes it")

        _ = apply(.post(id: "deploy", text: "Deploying", title: nil, icon: nil, tint: nil, seconds: 600), activities: activities, model: model)
        let long = activities.activity(id: "cli.deploy")
        let staleSequence = (long?.sequence ?? 0) - 1
        collapseNow("cli.deploy", sequence: staleSequence, in: activities)
        let untouched = activities.activity(id: "cli.deploy")?.expands == true
        collapseNow("cli.deploy", sequence: long?.sequence ?? -1, in: activities)
        let collapsed = activities.activity(id: "cli.deploy")
        check(long?.expands == true && long?.duration == 600 && untouched
              && collapsed?.expands == false && collapsed?.actions.map(\.id) == ["dismiss"] && collapsed?.duration == 600,
              "cli: a long --for peeks first, then collapses with a Dismiss button (only if not replaced since)")
        activities.remove(id: "cli.deploy")

        _ = apply(.progress(id: "render", fraction: 0.25, title: "Rendering"), activities: activities, model: model)
        let firstSequence = activities.activity(id: "cli.render")?.sequence
        _ = apply(.progress(id: "render", fraction: 0.5, title: nil), activities: activities, model: model)
        let ring = activities.activity(id: "cli.render")
        check(ring?.accessory == .progress(0.5) && ring?.title == "Rendering" && ring?.subtitle == "50%"
              && ring?.sequence == firstSequence && ring?.duration == nil,
              "cli: progress updates the ring in place and keeps the title")
        _ = apply(.done(id: "render", text: nil), activities: activities, model: model)
        let done = activities.activity(id: "cli.render")
        check(done?.duration == doneSeconds && done?.accessory == .text("Done") && done?.tint == .green
              && done?.title == "Rendering" && done?.symbol == "checkmark.circle.fill",
              "cli: done turns it into a 6 s check mark")
        _ = apply(.remove(id: "render"), activities: activities, model: model)
        check(activities.activity(id: "cli.render") == nil && apply(.remove(id: "never"), activities: activities, model: model) == nil,
              "cli: remove takes it away, and removing a missing id is fine")

        for i in 0..<maxActivities {
            _ = apply(.post(id: "m\(i)", text: "x", title: nil, icon: nil, tint: nil, seconds: 0), activities: activities, model: model)
        }
        check(apply(.post(id: "one-more", text: "x", title: nil, icon: nil, tint: nil, seconds: 0), activities: activities, model: model) != nil
              && apply(.post(id: "m0", text: "again", title: nil, icon: nil, tint: nil, seconds: 0), activities: activities, model: model) == nil,
              "cli: at most 16 messages at once, but replacing one is always fine")
        check(apply(.open(tab: .clipboard), activities: activities, model: model) != nil && !model.isOpen,
              "cli: open reports an error when there's no notch to show")
    }

    /// Nothing of its own to draw: its activities use the notch's standard look.
    static func snapshotViews() -> [(name: String, view: AnyView)] { [] }
}
