import AppKit
import SwiftUI

/// A borderless panel that takes typing without activating the app, on every Space
/// (fullscreen ones too), above the notch.
final class CaptureWindow: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: CGRect(origin: .zero, size: CapturePanelController.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// ⌘X, ⌘C, ⌘V, ⌘A, ⌘Z and ⇧⌘Z in the field. The app is never active, so the box
    /// handles them itself rather than counting on the Edit menu to see them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        EditKeys.perform(event, in: self) || super.performKeyEquivalent(with: event)
    }
}

/// Shows the capture box under the notch. Return saves, Esc cancels and clears, clicking
/// anywhere else hides it and keeps the draft for next time.
@MainActor
final class CapturePanelController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    static let size = CGSize(width: 520, height: 72)
    static let gap: CGFloat = 10           // between the notch (or menu bar) and the box

    /// Gets the text on Return. Returns false when there was nothing to save.
    var onSubmit: ((String) -> Bool)?

    private let window = CaptureWindow()
    private let field = NSTextField()
    private let host: NSHostingView<CapturePanelView>
    private var clickMonitor: Any?

    override init() {
        host = NSHostingView(rootView: CapturePanelView(fileName: "", field: nil))
        super.init()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.textColor = .white
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.placeholderAttributedString = NSAttributedString(string: CapturePanelView.placeholder, attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.4), .font: NSFont.systemFont(ofSize: 15),
        ])
        field.delegate = self
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: Self.size)
        window.contentView = host
        window.delegate = self
        window.onCancel = { [weak self] in self?.cancel() }
    }

    var isVisible: Bool { window.isVisible }

    /// Shows the box with the cursor in the field, after any draft left from last time.
    func show(fileName: String) {
        host.rootView = CapturePanelView(fileName: fileName, field: field)
        host.layoutSubtreeIfNeeded()           // puts the field in the window before focusing it
        window.setFrame(Self.frame(notch: NotchGeometry.current(), screen: Self.pointerScreen()?.visibleFrame),
                        display: false)
        window.orderFrontRegardless()
        window.makeKey()
        if !focusField() {
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { _ = self?.focusField() } }
        }
        installClickMonitor()
    }

    /// Puts the cursor at the end of the draft. False while SwiftUI hasn't placed the field yet.
    @discardableResult
    private func focusField() -> Bool {
        guard field.window === window, window.makeFirstResponder(field) else { return false }
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        return true
    }

    /// Puts text back after a failed save.
    func restore(_ text: String) {
        if field.stringValue.isEmpty { field.stringValue = text }
    }

    func hide() {
        removeClickMonitor()
        guard window.isVisible else { return }
        window.orderOut(nil)
    }

    func cancel() {
        field.stringValue = ""
        hide()
    }

    private func submit() {
        let text = field.stringValue
        if onSubmit?(text) ?? false { field.stringValue = "" }
        hide()
    }

    /// Under the notch, centered on it; with no notch (lid closed), under the menu bar of the
    /// screen the pointer is on.
    static func frame(notch: NotchGeometry?, screen visible: CGRect?) -> CGRect {
        let s = size
        if let g = notch {
            return CGRect(x: (g.centerX - s.width / 2).rounded(), y: g.top - g.notchSize.height - gap - s.height,
                          width: s.width, height: s.height)
        }
        let v = visible ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGRect(x: (v.midX - s.width / 2).rounded(), y: v.maxY - gap - s.height, width: s.width, height: s.height)
    }

    private static func pointerScreen() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }

    // MARK: Delegates

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            submit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    /// A click in another app doesn't always take key status from a panel of an app that
    /// was never active, so watch for it too.
    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }
}

/// The capture box's look. `field` is the live text field; snapshots pass nil and a sample
/// text instead.
struct CapturePanelView: View {
    static let placeholder = "Capture a thought…"

    let fileName: String
    let field: NSTextField?
    var sampleText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                if let field {
                    CaptureFieldHost(field: field)
                } else {
                    Text(sampleText.isEmpty ? Self.placeholder : sampleText)
                        .font(.system(size: 15))
                        .foregroundStyle(sampleText.isEmpty ? NotchStyle.tertiary : Color.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 22)
            HStack(spacing: 10) {
                Text("Adds a to-do to \(fileName)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(NotchStyle.tertiary)
                Spacer(minLength: 8)
                CaptureKeyHint(key: "↩", label: "save")
                CaptureKeyHint(key: "esc", label: "cancel")
            }
            .font(NotchStyle.smallFont)
            .padding(.leading, 28)
        }
        .padding(.horizontal, 16)
        .frame(width: CapturePanelController.size.width, height: CapturePanelController.size.height)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }
}

private struct CaptureKeyHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .foregroundStyle(NotchStyle.secondary)
            Text(label).foregroundStyle(NotchStyle.tertiary)
        }
    }
}

/// Hosts the controller's text field, which outlives any one SwiftUI update. It takes the
/// width it's offered, not its text's width, so a long draft scrolls instead of widening the row.
private struct CaptureFieldHost: NSViewRepresentable {
    let field: NSTextField

    func makeNSView(context: Context) -> NSTextField { field }
    func updateNSView(_ nsView: NSTextField, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: 22)
    }
}
