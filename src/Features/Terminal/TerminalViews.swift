import AppKit
import SwiftUI

/// Where the shared terminal view is showing.
enum TerminalSurface {
    case dropdown, notch
}

enum TerminalResizePhase {
    case began, changed, ended
}

/// What the terminal's SwiftUI chrome shows, and the actions it calls. Owned by the
/// feature; the snapshots build one from sample data with no-op actions.
@MainActor
final class TerminalStore: ObservableObject {
    struct Tab: Identifiable, Equatable {
        let id: Int
        var title: String
        var busy: Bool
    }

    struct Extra {
        var title: String
        var symbol: String
        var view: () -> AnyView
    }

    @Published var tabs: [Tab] = []
    @Published var activeID: Int?
    @Published var extraTab: Int?            // a dropdown tab (Usage) instead of the terminal
    @Published var pinned = false
    @Published var surface: TerminalSurface = .dropdown
    @Published var pendingClose: (id: Int, name: String)?
    @Published var hotkeyLabel = "⌃`"
    @Published var extraTabs: [Extra] = []

    var select: (Int) -> Void = { _ in }
    var close: (Int) -> Void = { _ in }
    var newTab: () -> Void = {}
    var selectExtra: (Int) -> Void = { _ in }
    var togglePin: () -> Void = {}
    var hide: () -> Void = {}
    var resize: (TerminalResizePhase) -> Void = { _ in }
    var showInNotch: () -> Void = {}
    /// A host view joined or left a window; the feature moves the terminal into it.
    var hostMoved: (TerminalSurface, TerminalHostView) -> Void = { _, _ in }
    var hostRemoved: (TerminalSurface, TerminalHostView) -> Void = { _, _ in }

    var showsTerminal: Bool { extraTab == nil }

    func isActive(_ tab: Tab) -> Bool { showsTerminal && tab.id == activeID }

    /// Two shells and a Usage tab, for snapshots.
    static func sample() -> TerminalStore {
        let store = TerminalStore()
        store.tabs = [Tab(id: 1, title: "dynamic-notch", busy: false), Tab(id: 2, title: "✳ Claude Code", busy: true)]
        store.activeID = 1
        store.extraTabs = [Extra(title: "Usage", symbol: "gauge.with.dots.needle.33percent") { AnyView(EmptyView()) }]
        return store
    }
}

// MARK: AppKit host

/// An empty container the active session's terminal view is moved into. Clicks fall
/// through it while it's empty, to the SwiftUI views around it.
final class TerminalHostView: NSView {
    var onWindow: ((TerminalHostView) -> Void)?
    var onDismantle: ((TerminalHostView) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindow?(self)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        subviews.isEmpty ? nil : super.hitTest(point)
    }

    private var pendingFit: DispatchWorkItem?

    /// Size changes settle for a moment before the terminal follows, so the notch's
    /// opening animation tells the shell its size once rather than once per frame
    /// (each resize reflows the scrollback and makes full-screen programs redraw).
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        pendingFit?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fit() }
        }
        pendingFit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// Shows `view` filling the host, taking it from wherever it was.
    func show(_ view: NSView) {
        for other in subviews where other !== view { other.removeFromSuperview() }
        if view.superview !== self {
            view.removeFromSuperview()
            addSubview(view)
        }
        view.autoresizingMask = []
        fit()
    }

    /// Sizes the terminal to the host once SwiftUI has given the host a real size. Sized
    /// to a host that isn't laid out yet, the shell would be told it has a few columns.
    private func fit() {
        guard bounds.width >= 60, bounds.height >= 30 else { return }
        for view in subviews where view.frame != bounds { view.frame = bounds }
    }

    func clear() {
        pendingFit?.cancel()
        for view in subviews { view.removeFromSuperview() }
    }
}

struct TerminalHostRepresentable: NSViewRepresentable {
    let surface: TerminalSurface
    let store: TerminalStore
    var hidden = false

    func makeNSView(context: Context) -> TerminalHostView {
        let host = TerminalHostView()
        // Until the host is laid out, the terminal keeps its size from the other surface;
        // never let it draw past the host.
        host.clipsToBounds = true
        let surface = surface
        host.onWindow = { [weak store] host in store?.hostMoved(surface, host) }
        host.onDismantle = { [weak store] host in store?.hostRemoved(surface, host) }
        return host
    }

    func updateNSView(_ host: TerminalHostView, context: Context) {
        if host.isHidden != hidden { host.isHidden = hidden }
    }

    static func dismantleNSView(_ host: TerminalHostView, coordinator: ()) {
        host.onDismantle?(host)
        host.clear()
    }
}

// MARK: Menu bar dropdown

/// The live dropdown: the chrome with the terminal host as its body.
struct TerminalDropdownView: View {
    @ObservedObject var store: TerminalStore

    var body: some View {
        TerminalDropdownChrome(store: store) {
            TerminalHostRepresentable(surface: .dropdown, store: store, hidden: !store.showsTerminal)
        }
    }
}

/// The dropdown's rounded black body: header row, then the terminal (or a dropdown
/// tab's view), and a resize grip in the bottom-right corner.
struct TerminalDropdownChrome<Terminal: View>: View {
    @ObservedObject var store: TerminalStore
    @ViewBuilder let terminal: () -> Terminal

    var body: some View {
        VStack(spacing: 0) {
            TerminalHeaderBar(store: store)
            ZStack {
                // The bottom margin holds the resize grip: the terminal is an AppKit view,
                // which would sit over (and take the clicks of) anything SwiftUI draws there.
                terminal()
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                    .padding(.bottom, TerminalResizeGrip.size)
                if let i = store.extraTab, store.extraTabs.indices.contains(i) {
                    store.extraTabs[i].view()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .overlay(alignment: .bottomTrailing) { TerminalResizeGrip(store: store) }
        .environment(\.colorScheme, .dark)
    }
}

/// Session tabs, +, the dropdown tabs (Usage), then pin and close.
struct TerminalHeaderBar: View {
    @ObservedObject var store: TerminalStore

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(store.tabs.enumerated()), id: \.element.id) { index, tab in
                TerminalSessionPill(tab: tab, index: index, selected: store.isActive(tab),
                                    pending: store.pendingClose?.id == tab.id ? store.pendingClose?.name : nil,
                                    select: { store.select(tab.id) }, close: { store.close(tab.id) })
            }
            TerminalIconButton(symbol: "plus", help: "New tab (⌘T)") { store.newTab() }
            if !store.extraTabs.isEmpty {
                Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1, height: 14).padding(.horizontal, 4)
                ForEach(store.extraTabs.indices, id: \.self) { i in
                    TerminalExtraPill(extra: store.extraTabs[i], selected: store.extraTab == i) { store.selectExtra(i) }
                }
            }
            Spacer(minLength: 8)
            TerminalIconButton(symbol: store.pinned ? "pin.fill" : "pin",
                               help: store.pinned ? "Unpin: hide when clicking elsewhere" : "Pin: stay open when clicking elsewhere",
                               highlighted: store.pinned) { store.togglePin() }
            TerminalIconButton(symbol: "xmark", help: "Hide (\(store.hotkeyLabel))") { store.hide() }
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
    }
}

private struct TerminalSessionPill: View {
    let tab: TerminalStore.Tab
    let index: Int
    let selected: Bool
    let pending: String?
    let select: () -> Void
    let close: () -> Void
    private let hover = State(initialValue: false)   // @State is a macro, unavailable without Xcode

    var body: some View {
        let hovering = hover.wrappedValue
        return HStack(spacing: 6) {
            Circle()
                .fill(tab.busy ? Color.green.opacity(0.9) : Color.white.opacity(0.22))
                .frame(width: 6, height: 6)
            Text(pending.map { "Press again to end \($0)" } ?? tab.title)
                .lineLimit(1)
                .truncationMode(.middle)
            if selected || hovering {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white.opacity(0.6))
                .help("Close tab (⌘W)")
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(pending != nil ? Color.orange : selected ? Color.white : Color.white.opacity(0.55))
        .padding(.leading, 9)
        .padding(.trailing, selected || hovering ? 4 : 9)
        .frame(height: 24)
        .frame(maxWidth: 190)
        .background(selected ? Color.white.opacity(0.14) : hovering ? Color.white.opacity(0.07) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture(perform: select)
        .onHover { hover.wrappedValue = $0 }
        .help(index < 9 ? "⌘\(index + 1)" : "")
    }
}

private struct TerminalExtraPill: View {
    let extra: TerminalStore.Extra
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 5) {
                Image(systemName: extra.symbol).font(.system(size: 11, weight: .semibold))
                Text(extra.title)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.55))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(selected ? Color.white.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct TerminalIconButton: View {
    let symbol: String
    let help: String
    var highlighted = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .foregroundStyle(highlighted ? Color.white : Color.white.opacity(0.55))
                .background(highlighted ? Color.white.opacity(0.14) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Three short diagonal strokes in the bottom-right corner; dragging resizes the dropdown.
private struct TerminalResizeGrip: View {
    /// The grip's square, which is also the dropdown's bottom margin.
    static let size: CGFloat = 14

    @ObservedObject var store: TerminalStore
    private let dragging = State(initialValue: false)   // @State is a macro, unavailable without Xcode

    var body: some View {
        Canvas { context, size in
            for k in [3.0, 6.0, 9.0] {
                var line = Path()
                line.move(to: CGPoint(x: size.width - 1, y: size.height - 1 - k))
                line.addLine(to: CGPoint(x: size.width - 1 - k, y: size.height - 1))
                context.stroke(line, with: .color(.white.opacity(0.35)), lineWidth: 1)
            }
        }
        .frame(width: Self.size - 4, height: Self.size - 4)
        .padding(2)
        .padding(.trailing, 2)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !dragging.wrappedValue {
                        dragging.wrappedValue = true
                        store.resize(.began)
                    }
                    store.resize(.changed)
                }
                .onEnded { _ in
                    dragging.wrappedValue = false
                    store.resize(.ended)
                }
        )
        .help("Drag to resize")
    }
}

// MARK: Notch tab

/// The live notch tab: the session rail beside the terminal host, or a placeholder when
/// the terminal is in the menu bar or every shell ended. Only one of the two exists, so
/// the empty AppKit host never sits over the placeholder's button.
struct TerminalNotchTab: View {
    @ObservedObject var store: TerminalStore

    var body: some View {
        TerminalNotchChrome(store: store) {
            if store.surface == .notch && !store.tabs.isEmpty {
                TerminalHostRepresentable(surface: .notch, store: store)
            } else {
                TerminalNotchPlaceholder(store: store)
            }
        }
    }
}

/// Session list on the left, the terminal on the right.
struct TerminalNotchChrome<Terminal: View>: View {
    @ObservedObject var store: TerminalStore
    @ViewBuilder let terminal: () -> Terminal
    private let maxRows = 5

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(store.tabs.prefix(maxRows).enumerated()), id: \.element.id) { index, tab in
                    row(tab, index: index)
                }
                if store.tabs.count > maxRows {
                    Text("+\(store.tabs.count - maxRows) more")
                        .font(NotchStyle.smallFont)
                        .foregroundStyle(NotchStyle.tertiary)
                        .padding(.horizontal, 8)
                }
                Button(action: store.newTab) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                        Text("New tab")
                        Spacer(minLength: 0)
                        Text("⌘T").font(NotchStyle.monoFont).foregroundStyle(NotchStyle.tertiary)
                    }
                    .font(NotchStyle.smallFont)
                    .foregroundStyle(NotchStyle.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                Text("\(store.hotkeyLabel) opens it in the menu bar")
                    .font(.system(size: 10))
                    .foregroundStyle(NotchStyle.tertiary)
                    .lineLimit(2)
                    .padding(.horizontal, 8)
            }
            .frame(width: 136, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)

            // Inset on every side: the terminal is an AppKit view, which would cover the
            // rounded corners and the border SwiftUI draws around it.
            terminal()
                .padding(.leading, 8)
                .padding(.trailing, 4)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        }
        .environment(\.colorScheme, .dark)
    }

    private func row(_ tab: TerminalStore.Tab, index: Int) -> some View {
        let selected = tab.id == store.activeID
        let pending = store.pendingClose?.id == tab.id ? store.pendingClose?.name : nil
        return HStack(spacing: 6) {
            Circle()
                .fill(tab.busy ? Color.green.opacity(0.9) : Color.white.opacity(0.22))
                .frame(width: 6, height: 6)
            Text(pending.map { "⌘W again: end \($0)" } ?? tab.title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if pending == nil {
                Text("⌘\(index + 1)").font(NotchStyle.monoFont).foregroundStyle(NotchStyle.tertiary)
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(pending != nil ? Color.orange : selected ? Color.white : NotchStyle.secondary)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(selected ? NotchStyle.cardHover : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { store.select(tab.id) }
    }
}

/// Shown when the notch has no terminal to host: it's in the menu bar, or every shell
/// ended.
private struct TerminalNotchPlaceholder: View {
    @ObservedObject var store: TerminalStore

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(NotchStyle.secondary)
            Text(store.tabs.isEmpty ? "The shell ended." : "The terminal is open in the menu bar.")
                .font(NotchStyle.bodyFont)
                .foregroundStyle(NotchStyle.secondary)
            Button(store.tabs.isEmpty ? "New Shell" : "Show Here", action: store.showInNotch)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Sample terminal text for snapshots, in place of the live terminal view.
struct TerminalSamplePrompt: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            line([("~/Code/dynamic-notch", .cyan), (" main", .green), (" ❯ ", .white), ("swift build", .white)])
            line([("Building for debugging...", .gray)])
            line([("Build complete! (4.21s)", .green)])
            line([("~/Code/dynamic-notch", .cyan), (" main", .green), (" ❯ ", .white), ("ls", .white)])
            line([("Package.swift  ", .white), ("SPEC.md  ", .white), ("scripts  ", .blue), ("src  ", .blue), ("vendor", .blue)])
            line([("~/Code/dynamic-notch", .cyan), (" main", .green), (" ❯ ", .white), ("█", .white)])
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, design: .monospaced))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 4)
        .background(Color.black)
    }

    private func line(_ parts: [(String, Color)]) -> some View {
        var text = AttributedString()
        for (string, color) in parts {
            var part = AttributedString(string)
            part.foregroundColor = color
            text += part
        }
        return Text(text).lineLimit(1)
    }
}
