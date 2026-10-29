import AppKit
import SwiftUI

extension CaptureFeature {
    /// Pure-logic checks: the line format, cleaning, appending (in a temporary folder that
    /// is removed afterwards), the hotkey setting, permission errors and where the box goes.
    static func selfTest(_ check: (Bool, String) -> Void) {
        CaptureNotchy.selfTest(check)
        let utc = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_793_024_700)          // 2026-10-26 14:25 UTC
        check(CaptureWriter.line(for: "Call the bank", at: date, timeZone: utc) == "- [ ] Call the bank  <!-- 2026-10-26 14:25 -->",
              "capture: a capture is an open to-do with the time in a comment")
        check(CaptureWriter.stamp(date, timeZone: TimeZone(identifier: "America/Chicago")!) == "2026-10-26 09:25",
              "capture: the time is local")
        check(CaptureWriter.clean("  two\nlines\tand  tabs \u{7} ") == "two lines and tabs",
              "capture: text becomes one tidy line")
        check(CaptureWriter.clean("- [ ] buy milk") == "buy milk" && CaptureWriter.clean("* eggs") == "eggs"
              && CaptureWriter.clean("[ ] bread") == "bread" && CaptureWriter.clean("-5 degrees") == "-5 degrees",
              "capture: a typed bullet or checkbox isn't doubled")
        check(CaptureWriter.clean("a <!-- b") == "a &lt;!-- b", "capture: a comment opener can't hide the timestamp")
        check(CaptureWriter.clean("\u{1F9D1}\u{200D}\u{1F4BB} fix deploy") == "\u{1F9D1}\u{200D}\u{1F4BB} fix deploy"
              && CaptureWriter.clean("a\u{2028}b") == "a b" && CaptureWriter.clean("abc\u{202E}gpj.exe") == "abcgpj.exe",
              "capture: emoji joiners stay; line separators become spaces; bidi overrides are dropped")
        check(CaptureWriter.line(for: " \n\t", at: date) == nil && CaptureWriter.line(for: "- ", at: date) == nil,
              "capture: blank text saves nothing")

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("dynamicnotch-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("nested/Quick Capture.md")
        func contents() -> String { (try? String(contentsOf: file, encoding: .utf8)) ?? "<missing>" }
        do {
            try CaptureWriter.append("- [ ] one", to: file)
            check(contents() == "# Quick Capture\n\n- [ ] one\n", "capture: a missing file (and folder) starts with the heading")
            try CaptureWriter.append("- [ ] two", to: file)
            check(contents() == "# Quick Capture\n\n- [ ] one\n- [ ] two\n", "capture: later captures are appended")
            try Data("# Inbox\n\n- [ ] edited by hand".utf8).write(to: file)
            try CaptureWriter.append("- [ ] three", to: file)
            check(contents() == "# Inbox\n\n- [ ] edited by hand\n- [ ] three\n",
                  "capture: a file without a final newline gets one first; your heading is kept")
            try Data().write(to: file)
            try CaptureWriter.append("- [ ] four", to: file)
            check(contents() == "# Quick Capture\n\n- [ ] four\n", "capture: an empty file gets the heading too")
        } catch {
            check(false, "capture: appending failed: \(error.localizedDescription)")
        }

        let defaults = Config()
        check(!hotkey(in: defaults).isEmpty && hotkey(in: defaults) == defaults.quickCaptureHotkey
              && HotkeyCenter.parse(hotkey(in: defaults)) != nil,
              "capture: the default hotkey is on and parses")
        var custom = Config()
        custom.quickCaptureHotkey = " cmd+shift+k "
        let trimmed = hotkey(in: custom)
        custom.quickCaptureHotkey = ""
        check(trimmed == "cmd+shift+k" && hotkey(in: custom).isEmpty,
              "capture: the hotkey setting is read and trimmed; an empty one turns the shortcut off")

        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                             userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        check(isPermissionError(denied) && isPermissionError(POSIXError(.EACCES))
              && !isPermissionError(CocoaError(.fileWriteOutOfSpace)) && !isPermissionError(POSIXError(.ENOENT)),
              "capture: a blocked folder is told apart from other write errors")

        let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
        if let g = NotchGeometry.compute(screenFrame: screen, safeTop: 32, leftWidth: 645.5, rightWidth: 645.5) {
            let f = CapturePanelController.frame(notch: g, screen: nil)
            check(f.midX == g.centerX && f.maxY == screen.maxY - 32 - CapturePanelController.gap && f.size == CapturePanelController.size,
                  "capture: the box sits centered just under the notch")
        } else {
            check(false, "capture: sample notch geometry")
        }
        let external = CGRect(x: 1470, y: 0, width: 1920, height: 1055)
        let f = CapturePanelController.frame(notch: nil, screen: external)
        check(f.midX == external.midX && f.maxY == external.maxY - CapturePanelController.gap && external.contains(f),
              "capture: with the lid closed it goes under the menu bar of the pointer's screen")
    }

    /// The capture box, empty and with a draft.
    static func snapshotViews() -> [(name: String, view: AnyView)] {
        func box(_ text: String) -> AnyView {
            AnyView(CapturePanelView(fileName: "Quick Capture.md", field: nil, sampleText: text)
                .frame(width: CapturePanelController.size.width, height: CapturePanelController.size.height)
                .background(Color(white: 0.55)))
        }
        return [
            ("capture-box", box("")),
            ("capture-box-draft", box("Ask Sam which logo we ship, light or dark")),
        ]
    }
}
