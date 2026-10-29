import SwiftUI

extension DraftsFeature {
    /// Pure-logic checks: counting asks, reading skim's state, ranking folders, the file
    /// watch filter, and a scan of a temporary folder that is removed afterwards.
    static func selfTest(_ check: (Bool, String) -> Void) {
        let doc = """
        # Draft

        > [!ASK] Which demo video?
        > The 60 s cut or the 2 min cut?

        > [!ask]- Lowercase and foldable
        >[!ASK]
        > (same box as the line above, so not counted again)

        > [!TODO] Not an ask.
        > [!ASK] Body text of the TODO box, not a new box.

        > A plain quote
        > [!ASK] whose first line wasn't the marker

        ```md
        > [!ASK] Inside a fence
        ```

        ~~~~
        ```
        > [!ASK] Inside a longer tilde fence, past a shorter backtick line
        ~~~~

        <!--
        > [!ASK] Inside a comment
        -->
            > [!ASK] Indented code
           > [!ASK] Three spaces is still a quote\r
        """
        check(DraftsAsks.count(in: doc) == 3, "drafts: counts ask boxes, not fenced, commented, indented or body ones")
        check(DraftsAsks.count(in: "> [!ASK] a\n\n> [!ASK] b\n> [!ASK] c") == 2,
              "drafts: a blank line starts a new box; a '>' line continues the old one")
        check(DraftsAsks.count(in: "```\n> [!ASK] never closed") == 0 && DraftsAsks.count(in: "") == 0
              && DraftsAsks.count(in: "> \n> [!ASK] after a blank quote line") == 1
              && DraftsAsks.count(in: "> [!ASKED] no") == 0 && DraftsAsks.count(in: "``` js ` x\n> [!ASK] y") == 1,
              "drafts: unclosed fences hide the rest; leading blank quote lines are skipped; only ASK counts")

        // skim's state.
        let rootsJSON = Data("""
        {"/Users/sam/Code/apps": {"first": "2026-10-20T02:38:33.530Z"},
         "/Users/sam/Code/notes": {"first": "2026-10-24T02:56:57Z"},
         "/Users/sam/notes/one.md": {}, "relative/path": {"first": "2026-10-25T00:00:00Z"}}
        """.utf8)
        let roots = DraftsDiscovery.parseRoots(rootsJSON)
        check(roots.count == 3 && roots["/Users/sam/notes/one.md"] == .distantPast && roots["relative/path"] == nil,
              "drafts: roots.json parses; a missing date counts as old; relative paths are ignored")
        let head = Data(##"{"path":"/Users/sam/Code/apps/Plan \"draft\" é.md","at":"2026-10-25T09:00:00.000Z","content":"# Plan"##.utf8)
        let seen = DraftsDiscovery.parseSeen(head)
        check(seen?.path == "/Users/sam/Code/apps/Plan \"draft\" é.md" && seen?.at == DraftsDiscovery.date("2026-10-25T09:00:00Z"),
              "drafts: a seen file's path and time come from its first bytes, escapes and all")
        check(DraftsDiscovery.parseSeen(Data(#"{"at":"2026-10-25T09:00:00Z","boxes":[],"path":"/x.md"}"#.utf8))?.path == "/x.md"
              && DraftsDiscovery.parseSeen(Data("not json".utf8)) == nil,
              "drafts: other key orders still parse; junk doesn't")
        let ranked = DraftsDiscovery.rank(roots: roots, seen: [
            (path: "/Users/sam/Code/apps/plan.md", at: DraftsDiscovery.date("2026-10-26T01:00:00Z")!),
            (path: "/Users/sam/Code/apps-old/x.md", at: DraftsDiscovery.date("2026-10-27T01:00:00Z")!),
        ])
        check(ranked == ["/Users/sam/Code/apps", "/Users/sam/Code/notes", "/Users/sam/notes/one.md"],
              "drafts: the folder you looked at last comes first (and /apps-old isn't inside /apps)")
        check(DraftsDiscovery.isProtected("/Users/sam/Documents/x", home: "/Users/sam")
              && DraftsDiscovery.isProtected("/Volumes/SSD/notes", home: "/Users/sam")
              && !DraftsDiscovery.isProtected("/Users/sam/Code/x", home: "/Users/sam")
              && !DraftsDiscovery.isProtected("/Users/sam/DocumentsArchive", home: "/Users/sam")
              && DraftsDiscovery.isProtected("/Users/sam/desktop/notes", home: "/Users/sam"),
              "drafts: folders macOS guards are skipped when found through skim")
        check(DraftsDiscovery.isAboveHome("/", home: "/Users/sam") && DraftsDiscovery.isAboveHome("/users", home: "/Users/sam")
              && !DraftsDiscovery.isAboveHome("/Users/sam", home: "/Users/sam") && !DraftsDiscovery.isAboveHome("/Users/sa", home: "/Users/sam")
              && !DraftsDiscovery.isAboveHome("/Users/sam/Code", home: "/Users/sam"),
              "drafts: / and /Users are above the home folder; home and folders in it aren't")
        check(DraftsWatcher.matters("/a/b/Notes.MD", skimState: "/h/.skim") && DraftsWatcher.matters("/h/.skim/roots.json", skimState: "/h/.skim")
              && !DraftsWatcher.matters("/h/.skim/history/x/1.md", skimState: "/h/.skim")
              && !DraftsWatcher.matters("/a/node_modules/x/README.md", skimState: nil) && !DraftsWatcher.matters("/a/b.txt", skimState: nil),
              "drafts: only Markdown changes and skim's folder list trigger a rescan")

        // A scan of a temporary folder, with a fake skim state.
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("dynamicnotch-drafts-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        func write(_ rel: String, _ text: String) {
            let url = dir.appendingPathComponent(rel)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: url)
        }
        let two = "> [!ASK] a\n\n> [!ASK] b\n"
        write("docs/a.md", two)
        write("docs/sub/b.markdown.md", "> [!ASK] c\n")
        write("docs/sub/none.md", "# nothing\n")
        write("docs/notes.txt", two)
        write("docs/.hidden/c.md", two)
        write("docs/node_modules/pkg/README.md", two)
        write("single.md", "> [!ASK] d\n")
        let scanner = DraftsScanner()
        let docs = dir.appendingPathComponent("docs").path
        var summary = scanner.scan(configured: [docs, dir.appendingPathComponent("single.md").path, docs + "/sub"])
        check(summary.totalAsks == 4 && summary.files.first?.name == "a"
              && Set(summary.files.map(\.name)) == ["a", "b.markdown", "single"]
              && summary.scannedFiles == 4 && !summary.fromSkim && summary.scanned,
              "drafts: a scan counts .md files, skips hidden ones and node_modules, and counts overlapping folders once")
        write("docs/a.md", "> [!ASK] only one now, and a longer file\n")
        summary = scanner.scan(configured: [docs])
        check(summary.totalAsks == 2 && summary.files.first?.asks == 1, "drafts: a changed file is read again")

        let state = dir.appendingPathComponent("skim-state", isDirectory: true)
        let stateRoots = #"{"\#(docs)": {"first": "2026-10-20T00:00:00Z"}, "\#(dir.path)/gone": {"first": "2026-10-26T00:00:00Z"}}"#
        write("skim-state/roots.json", stateRoots)
        summary = scanner.scan(configured: [], skimState: state)
        check(summary.fromSkim && summary.roots == [docs] && summary.totalAsks == 2,
              "drafts: with no folders set, skim's existing recent folders are used")

        // A fake home folder opened in skim (`skim ~`), next to "/". Resolved, so the walk's
        // paths and the guarded ones agree however the temporary folder is spelled.
        let home = dir.resolvingSymlinksInPath().appendingPathComponent("home", isDirectory: true).path
        write("home/Code/app/notes.md", "> [!ASK] e\n")
        write("home/Documents/secret.md", two)
        write("home/desktop/pitch.md", two)                 // the disk ignores case
        write("home/Library/Containers/app/x.md", two)
        let homeState = dir.appendingPathComponent("home-state", isDirectory: true)
        write("home-state/roots.json", #"{"\#(home)": {"first": "2026-10-20T00:00:00Z"}, "/": {"first": "2026-10-26T00:00:00Z"}}"#)
        summary = scanner.scan(configured: [], skimState: homeState, home: home)
        check(summary.roots == [home] && summary.files.map(\.name) == ["notes"] && summary.scannedFiles == 1,
              "drafts: through skim, a home folder is walked without Documents, desktop or Library, and / not at all")
        summary = scanner.scan(configured: [home], home: home)
        check(summary.totalAsks == 7 && summary.scannedFiles == 4, "drafts: a folder you set is walked in full")
    }

    /// The Home card with sample drafts, and its empty state.
    static func snapshotViews() -> [(name: String, view: AnyView)] {
        let now = Date(timeIntervalSince1970: 1_793_024_700)
        let busy = DraftsModel()
        busy.summary = DraftsSummary(
            files: [DraftsFile(path: "/Users/you/Code/notes/launch-plan.md", asks: 3, modified: now),
                    DraftsFile(path: "/Users/you/Code/notes/ROADMAP.md", asks: 2, modified: now),
                    DraftsFile(path: "/Users/you/Code/dynamic-notch/SPEC.md", asks: 2, modified: now),
                    DraftsFile(path: "/Users/you/Code/notes/grant-draft.md", asks: 1, modified: now)],
            roots: ["/Users/you/Code/notes", "/Users/you/Code/dynamic-notch"], fromSkim: true, scannedFiles: 31, scanned: true)
        let calm = DraftsModel()
        calm.summary = DraftsSummary(roots: ["/Users/you/Code/notes"], fromSkim: true, scannedFiles: 12, scanned: true)

        func card(_ model: DraftsModel) -> AnyView {
            AnyView(DraftsHomeCard(model: model, actions: DraftsActions(canCapture: { true }))
                .frame(width: 145, height: 186)
                .background(NotchStyle.card, in: RoundedRectangle(cornerRadius: NotchStyle.cornerRadius, style: .continuous))
                .background(Color.black)
                .environment(\.colorScheme, .dark))
        }
        return [("drafts-card", card(busy)), ("drafts-card-empty", card(calm))]
    }
}
