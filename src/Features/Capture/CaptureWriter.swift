import Foundation

/// Turns captured text into a Markdown line and appends it to the capture file.
///
/// Each capture is an open to-do with the time in an HTML comment, which Markdown viewers
/// (skim, GitHub) hide:
///
///     - [ ] Call the bank about the card  <!-- 2026-10-26 14:05 -->
///
/// A missing (or empty) file starts with a "# Quick Capture" heading.
enum CaptureWriter {
    static let heading = "# Quick Capture"

    /// The text as one clean line: control characters and runs of whitespace become one
    /// space (emoji joiners and other format characters stay, as for `notch post`), a bullet
    /// or checkbox typed out of habit is dropped, and "<!--" is defused so it can't hide the
    /// rest of the line. nil when nothing is left.
    static func clean(_ text: String) -> String? {
        var line = CLICommand.oneLine(text)
        let padded = line + " "                 // so a bullet on its own ("-") matches too
        for bullet in ["- [ ] ", "* [ ] ", "[ ] ", "- ", "* ", "+ "] where padded.hasPrefix(bullet) {
            line = String(padded.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        line = line.replacingOccurrences(of: "<!--", with: "&lt;!--")
        return line.isEmpty ? nil : line
    }

    /// The line to append, or nil for blank text.
    static func line(for text: String, at date: Date, timeZone: TimeZone = .current) -> String? {
        guard let body = clean(text) else { return nil }
        return "- [ ] \(body)  <!-- \(stamp(date, timeZone: timeZone)) -->"
    }

    /// "2026-10-26 14:05", in the given time zone, whatever the user's locale.
    static func stamp(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    /// Appends one line, creating the file (and its folder) with the heading if needed, and
    /// starting a new line if the file doesn't end with one. Blocking file IO: call it off the
    /// main thread.
    static func append(_ line: String, to url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("\(heading)\n\n\(line)\n".utf8).write(to: url, options: .withoutOverwriting)
            return
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        var text = line + "\n"
        if end == 0 {
            text = "\(heading)\n\n" + text
        } else {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([0x0A]) { text = "\n" + text }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: Data(text.utf8))
    }
}
