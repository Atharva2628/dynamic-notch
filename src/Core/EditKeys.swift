import AppKit

/// ⌘X, ⌘C, ⌘V, ⌘A, ⌘Z and ⇧⌘Z for text fields in the app's panels. AppKit normally gets
/// these from the Edit menu; the app is never active and shows no menu bar, so the panels
/// call this from `performKeyEquivalent` instead. Only a focused field editor (or other
/// text view) is touched: the terminal and its own shortcuts go first, in their monitors.
enum EditKeys {
    static let undo = Selector(("undo:"))
    static let redo = Selector(("redo:"))

    @MainActor
    static func perform(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.type == .keyDown, let editor = window.firstResponder as? NSTextView,
              let action = action(event.modifierFlags, event.charactersIgnoringModifiers) else { return false }
        if action == undo, editor.undoManager?.canUndo != true { return false }
        if action == redo, editor.undoManager?.canRedo != true { return false }
        return editor.tryToPerform(action, with: nil)
    }

    /// The edit action for a key, whatever Caps Lock and the Fn key are doing.
    static func action(_ flags: NSEvent.ModifierFlags, _ characters: String?) -> Selector? {
        guard let key = characters?.lowercased() else { return nil }
        let mods = flags.intersection([.command, .shift, .option, .control])
        if mods == [.command, .shift] { return key == "z" ? redo : nil }
        guard mods == .command else { return nil }
        switch key {
        case "x": return #selector(NSText.cut(_:))
        case "c": return #selector(NSText.copy(_:))
        case "v": return #selector(NSText.paste(_:))
        case "a": return #selector(NSText.selectAll(_:))
        case "z": return undo
        default: return nil
        }
    }
}
