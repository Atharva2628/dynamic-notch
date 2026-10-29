import AppKit

/// Notchy's to-do list, brought into the Quick Capture file once you ask (menu: Import
/// Notchy To-dos). Read-only on Notchy's settings: "todo.items" is JSON
/// `[{id, title, isDone, createdAt}]`, stored as data or a string.
enum CaptureNotchy {
    struct Todo: Equatable {
        var title: String
        var done: Bool
        var created: Date?
    }

    static func todos(fromDefaults dict: [String: Any]) -> [Todo] {
        let raw = dict["todo.items"]
        guard let json = (raw as? Data) ?? (raw as? String).map({ Data($0.utf8) }),
              let list = (try? JSONSerialization.jsonObject(with: json)) as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let title = entry["title"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Todo(title: title, done: entry["isDone"] as? Bool ?? false, created: date(entry["createdAt"]))
        }
    }

    /// Notchy stores dates as seconds since 2001 (Swift's default Codable date) or ISO text.
    private static func date(_ value: Any?) -> Date? {
        if let seconds = value as? Double { return Date(timeIntervalSinceReferenceDate: seconds) }
        if let text = value as? String { return ISO8601DateFormatter().date(from: text) }
        return nil
    }

    /// The Quick Capture line for a to-do, checked off when it's done.
    static func line(for todo: Todo, importedAt now: Date) -> String? {
        guard let line = CaptureWriter.line(for: todo.title, at: todo.created ?? now) else { return nil }
        return todo.done ? "- [x]" + line.dropFirst("- [ ]".count) : line
    }

    /// The to-dos whose text isn't in the file yet, so importing twice adds nothing.
    static func new(_ todos: [Todo], existing: String) -> [Todo] {
        todos.filter { todo in
            guard let body = CaptureWriter.clean(todo.title) else { return false }
            return !existing.contains("] \(body)  <!--") && !existing.contains("] \(body)\n")
        }
    }

    @MainActor
    static func selfTest(_ check: (Bool, String) -> Void) {
        let json = #"[{"id":"a","title":"Email Jamie","isDone":false,"createdAt":783000000},{"id":"b","title":"Book room","isDone":true,"createdAt":783000100},{"id":"c","title":"  ","isDone":false}]"#
        let fromData = todos(fromDefaults: ["todo.items": Data(json.utf8)])
        let fromString = todos(fromDefaults: ["todo.items": json])
        check(fromData.count == 2 && fromData == fromString, "capture: Notchy to-dos parse from data or text, blank ones skipped")
        check(fromData.first?.created == Date(timeIntervalSinceReferenceDate: 783000000), "capture: Notchy to-do dates are read")
        check(todos(fromDefaults: [:]).isEmpty && todos(fromDefaults: ["todo.items": "nope"]).isEmpty,
              "capture: no or broken Notchy to-dos give an empty list")
        let done = line(for: fromData[1], importedAt: Date())
        check(done?.hasPrefix("- [x] Book room  <!-- ") == true, "capture: a done Notchy to-do is checked off")
        let existing = "# Quick Capture\n\n- [ ] Email Jamie  <!-- 2025-10-23 10:00 -->\n"
        check(new(fromData, existing: existing).map(\.title) == ["Book room"], "capture: importing again skips to-dos already there")
    }
}

extension CaptureFeature {
    /// Appends Notchy's to-dos to the Quick Capture file, off the main thread, and says how
    /// many came over.
    func importNotchyTodos() {
        let url = Config.expand(context.config.quickCaptureFile)
        DispatchQueue.global(qos: .userInitiated).async {
            let todos = PrompterNotchy.exportDefaults()
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
                .map(CaptureNotchy.todos(fromDefaults:)) ?? []
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let fresh = CaptureNotchy.new(todos, existing: existing)
            var result: Result<Int, Error> = .success(0)
            do {
                for todo in fresh {
                    if let line = CaptureNotchy.line(for: todo, importedAt: Date()) { try CaptureWriter.append(line, to: url) }
                }
                result = .success(fresh.count)
            } catch {
                result = .failure(error)
            }
            let found = todos.count
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self = CaptureFeature.shared else { return }
                    let title: String
                    switch result {
                    case .success(let n) where found == 0: title = "No Notchy to-dos found"; _ = n
                    case .success(let n): title = n == 0 ? "Notchy to-dos already imported" : "Imported \(n) Notchy to-do\(n == 1 ? "" : "s")"
                    case .failure(let error): title = "Couldn't import: \(error.localizedDescription)"
                    }
                    self.context.activities.post(Activity(
                        id: "capture.notchy", priority: .info, symbol: "checklist", tint: .green,
                        title: title, subtitle: url.lastPathComponent, duration: 5, urgent: true))
                }
            }
        }
    }
}
