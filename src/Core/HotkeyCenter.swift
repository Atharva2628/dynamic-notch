import AppKit
import Carbon.HIToolbox

/// Global keyboard shortcuts through Carbon's RegisterEventHotKey, which needs neither
/// Accessibility nor Input Monitoring permission.
@MainActor
final class HotkeyCenter {
    struct Hotkey: Equatable {
        var keyCode: UInt32
        var modifiers: UInt32        // Carbon flags: cmdKey, optionKey, controlKey, shiftKey
    }

    static let shared = HotkeyCenter()

    private var actions: [UInt32: () -> Void] = [:]
    private var keys: [UInt32: Hotkey] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var waiting: [UInt32: String] = [:]     // in use by another app; tried again later
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?
    private var quitObserver: NSObjectProtocol?

    /// Registers a shortcut written like "ctrl+`", "ctrl+alt+v" or "cmd+shift+space".
    /// Returns an id for `unregister`, or nil if the text doesn't parse or another feature
    /// here already uses the shortcut.
    ///
    /// Registration is exclusive, so a shortcut another app already registered (Notchy,
    /// say) is detected: it's logged, and tried again under the same id whenever an app
    /// quits. While this app holds a shortcut, apps that register it later don't get it.
    /// Shortcuts macOS itself reserves (Spotlight, input sources) aren't detected.
    @discardableResult
    func register(_ text: String, action: @escaping () -> Void) -> UInt32? {
        guard let key = Self.parse(text) else {
            Log.app.error("hotkey \(text, privacy: .public) doesn't parse")
            return nil
        }
        guard !keys.values.contains(key) else {
            Log.app.error("hotkey \(text, privacy: .public) is already used by another feature")
            return nil
        }
        installHandler()
        let id = nextID
        nextID += 1
        let status = attach(key, id: id)
        if status == OSStatus(eventHotKeyExistsErr) {
            Log.app.error("hotkey \(text, privacy: .public) is held by another app; trying again when an app quits")
            waiting[id] = text
            watchQuits()
        } else if status != noErr {
            Log.app.error("hotkey \(text, privacy: .public) can't be registered (\(status))")
            return nil
        }
        keys[id] = key
        actions[id] = action
        return id
    }

    func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        waiting[id] = nil
        keys[id] = nil
        actions[id] = nil
    }

    private func attach(_ key: Hotkey, id: UInt32) -> OSStatus {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(key.keyCode, key.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        if status == noErr, let ref { refs[id] = ref }
        return status
    }

    /// An app that quit (Notchy) may have let go of a shortcut that was in use.
    private func watchQuits() {
        guard quitObserver == nil else { return }
        quitObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Give the system a moment to drop the quitting app's shortcuts.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated { self?.retryWaiting() }
            }
        }
    }

    private func retryWaiting() {
        for (id, text) in waiting {
            guard let key = keys[id], attach(key, id: id) == noErr else { continue }
            waiting[id] = nil
            Log.app.info("hotkey \(text, privacy: .public) registered now that it's free")
        }
    }

    fileprivate func fire(_ id: UInt32) { actions[id]?() }

    private static let signature: OSType = 0x444E_4F54   // "DNOT"

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKey = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard status == noErr, hotKey.signature == HotkeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            let id = hotKey.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotkeyCenter.shared.fire(id) } }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    /// Parses "ctrl+alt+v" style text. Modifier names: cmd/command, ctrl/control,
    /// alt/opt/option, shift. Keys: a-z, 0-9, f1-f12, space, return, tab, escape, and
    /// ` - = [ ] \ ; ' , . /
    nonisolated static func parse(_ text: String) -> Hotkey? {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let keyName = parts.last, !keyName.isEmpty || text.hasSuffix("+") else { return nil }
        var modifiers: UInt32 = 0
        for name in parts.dropLast() {
            switch name.trimmingCharacters(in: .whitespaces) {
            case "cmd", "command": modifiers |= UInt32(cmdKey)
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            case "alt", "opt", "option": modifiers |= UInt32(optionKey)
            case "shift": modifiers |= UInt32(shiftKey)
            default: return nil
            }
        }
        guard modifiers != 0, let code = keyCodes[keyName.trimmingCharacters(in: .whitespaces)] else { return nil }
        return Hotkey(keyCode: UInt32(code), modifiers: modifiers)
    }

    nonisolated private static let keyCodes: [String: Int] = {
        var map: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
            "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
            "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
            "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
            "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "`": kVK_ANSI_Grave, "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal,
            "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash,
            ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
            "/": kVK_ANSI_Slash,
            "space": kVK_Space, "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab,
            "escape": kVK_Escape, "esc": kVK_Escape,
        ]
        let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (i, code) in fKeys.enumerated() { map["f\(i + 1)"] = code }
        return map
    }()
}
