import AppKit
import SwiftUI

/// What the clipboard tab is showing: the search, the filter and the selected entry.
/// Shared by the views and the feature's keyboard handling.
@MainActor
final class ClipboardViewState: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { selectedID = nil } } }
    @Published var pinnedOnly = false { didSet { if pinnedOnly != oldValue { selectedID = nil } } }
    @Published var selectedID: UUID?
    @Published private(set) var focusRequest = 0
    @Published var access = ClipboardAccess.allowed
    @Published var paused = false
    /// The entry being copied back while its image file is read; its row is dimmed, and
    /// other copies are ignored until it's done.
    @Published var copyingID: UUID?

    /// The selected entry, or the first one when nothing (or something filtered out) is selected.
    func selection(in visible: [ClipboardItem]) -> ClipboardItem? {
        visible.first { $0.id == selectedID } ?? visible.first
    }

    func move(_ delta: Int, in visible: [ClipboardItem]) {
        selectedID = Self.moved(from: selection(in: visible)?.id, by: delta, in: visible.map(\.id))
    }

    /// Moves `delta` rows from `current`, stopping at either end.
    nonisolated static func moved(from current: UUID?, by delta: Int, in ids: [UUID]) -> UUID? {
        guard !ids.isEmpty else { return nil }
        let i = current.flatMap { ids.firstIndex(of: $0) } ?? 0
        return ids[min(max(i + delta, 0), ids.count - 1)]
    }

    /// Each time the tab opens: empty search, top entry selected, search field focused.
    func prepareForShow() {
        query = ""
        pinnedOnly = false
        selectedID = nil
        focusRequest += 1
    }

    func requestFocus() { focusRequest += 1 }
}

/// What the views can ask the feature to do. No-ops by default (snapshots).
struct ClipboardActions {
    var copy: (ClipboardItem) -> Void = { _ in }
    var remove: (UUID) -> Void = { _ in }
    var togglePin: (UUID) -> Void = { _ in }
    var open: (ClipboardItem) -> Void = { _ in }     // a link in the browser, files in Finder
    var showTab: () -> Void = {}
    var searchFocused: () -> Void = {}                // the search field just took focus
    var openPrivacySettings: () -> Void = {}
}

enum ClipboardFormat {
    /// "now", "5m", "3h", "2d", then the date.
    static func relative(_ date: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(date))
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(Int(s / 60))m"
        case ..<86_400: return "\(Int(s / 3600))h"
        case ..<(7 * 86_400): return "\(Int(s / 86_400))d"
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    static func title(_ item: ClipboardItem) -> String {
        switch item.kind {
        case .text: "Text"
        case .link: "Link"
        case .image: "Image"
        case .color: "Color"
        case .files:
            (item.paths?.count ?? 0) == 1 ? "File" : "\(item.paths?.count ?? 0) Files"
        }
    }

    /// The second line in the preview: size, length or values.
    static func details(_ item: ClipboardItem) -> String {
        switch item.kind {
        case .text:
            let lines = item.text.split(whereSeparator: \.isNewline).count
            let chars = item.text.count.formatted()
            return lines > 1 ? "\(chars) characters, \(lines) lines" : "\(chars) characters"
        case .link:
            return URL(string: item.text)?.host ?? ""
        case .image:
            return item.text.replacingOccurrences(of: "Image ", with: "")
        case .color:
            guard let c = item.color else { return "" }
            let rgb = [c.red, c.green, c.blue].map { String(ClipboardRGBA.byte($0)) }.joined(separator: ", ")
            return c.alpha < 1 ? "rgba(\(rgb), \(String(format: "%.2f", Double(ClipboardRGBA.byte(c.alpha)) / 255)))" : "rgb(\(rgb))"
        case .files:
            return (item.paths?.first).map { ($0 as NSString).deletingLastPathComponent } ?? ""
        }
    }
}

/// Decoded thumbnails, so scrolling doesn't decode PNGs again.
@MainActor
enum ClipboardThumbnailCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for item: ClipboardItem) -> NSImage? {
        guard let data = item.thumbnail else { return nil }
        let key = item.fingerprint as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

// MARK: Tab

/// The Clipboard tab: search and list on the left, the selected entry on the right.
struct ClipboardTabView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var state: ClipboardViewState
    let actions: ClipboardActions
    /// Set for snapshots: a fixed clock, and plain views in place of AppKit-backed ones.
    var snapshotDate: Date? = nil

    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if let snapshotDate {
                content(now: snapshotDate)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in content(now: context.date) }
            }
        }
        .onAppear { focusSearch() }
        .onChange(of: state.focusRequest) { focusSearch() }
        .onChange(of: searchFocused) { _, focused in if focused { actions.searchFocused() } }
    }

    private func content(now: Date) -> some View {
        let visible = ClipboardStore.filter(store.items, query: state.query, pinnedOnly: state.pinnedOnly)
        let selected = state.selection(in: visible)
        return HStack(spacing: 12) {
            VStack(spacing: 6) {
                header(count: visible.count)
                if state.access == .asks || (state.access == .denied && !visible.isEmpty) { accessBanner }
                if visible.isEmpty {
                    emptyState
                } else {
                    list(visible, selected: selected?.id, now: now)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            ClipboardPreview(item: selected, imageURL: selected.flatMap { store.imageURL(for: $0) },
                             now: now, actions: actions, isSnapshot: snapshotDate != nil)
                .frame(width: 240)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Focus lands after the panel has become the key window.
    private func focusSearch() {
        guard snapshotDate == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NotchStyle.tertiary)
                if snapshotDate != nil {
                    Text(state.query.isEmpty ? "Search" : state.query)
                        .font(NotchStyle.bodyFont)
                        .foregroundStyle(state.query.isEmpty ? NotchStyle.tertiary : Color.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("Search", text: $state.query)
                        .textFieldStyle(.plain)
                        .font(NotchStyle.bodyFont)
                        .foregroundStyle(.white)
                        .focused($searchFocused)
                }
                if !state.query.isEmpty {
                    Button { state.query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(NotchStyle.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(NotchStyle.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            ClipboardChip(symbol: state.pinnedOnly ? "pin.fill" : "pin", title: "Pinned", active: state.pinnedOnly) {
                state.pinnedOnly.toggle()
            }
            .help("Show only pinned items")

            Text(state.paused ? "Paused" : "\(count)")
                .font(NotchStyle.smallFont)
                .monospacedDigit()
                .foregroundStyle(state.paused ? Color.orange : NotchStyle.tertiary)
                .frame(minWidth: 22, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func list(_ visible: [ClipboardItem], selected: UUID?, now: Date) -> some View {
        let rows = ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
            ClipboardRow(item: item, index: index, selected: item.id == selected, copying: item.id == state.copyingID,
                         now: now, actions: actions)
                .id(item.id)
        }
        if snapshotDate != nil {
            // minHeight 0: take the height offered, as the live ScrollView does, instead of
            // growing to fit every row.
            VStack(spacing: 2) { rows }
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                .clipped()
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 2) { rows }
                }
                .scrollIndicators(.never)
                .onChange(of: state.selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
                }
            }
        }
    }

    /// macOS asks before each read (so history doesn't read at all), or denies it: say
    /// where to change that.
    private var accessBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.orange)
            Text(state.access == .denied ? "Clipboard access is off, so new copies aren't recorded."
                                         : "Paused by macOS. Set Paste from Other Apps to Always Allow.")
                .font(NotchStyle.smallFont)
                .foregroundStyle(NotchStyle.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            ClipboardChip(symbol: "gearshape", title: "Settings", active: false, action: actions.openPrivacySettings)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: store.items.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(NotchStyle.secondary)
            if state.access == .denied {
                Text("Clipboard access is off")
                    .font(NotchStyle.titleFont)
                    .foregroundStyle(.white)
                Text("Allow Dynamic Notch in Privacy & Security, Paste from Other Apps.")
                    .font(NotchStyle.smallFont)
                    .foregroundStyle(NotchStyle.secondary)
                    .multilineTextAlignment(.center)
                ClipboardChip(symbol: "gearshape", title: "Open Settings", active: false, action: actions.openPrivacySettings)
            } else if store.items.isEmpty {
                Text("Copy something and it shows up here.")
                    .font(NotchStyle.bodyFont)
                    .foregroundStyle(NotchStyle.secondary)
            } else {
                Text(state.pinnedOnly && state.query.isEmpty ? "Nothing pinned yet. ⌘P pins the selected item."
                                                            : "No matches for “\(state.query)”")
                    .font(NotchStyle.bodyFont)
                    .foregroundStyle(NotchStyle.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One entry in the list: icon or thumbnail, one line, age, pin and its ⌘ number.
private struct ClipboardRow: View {
    let item: ClipboardItem
    let index: Int
    let selected: Bool
    let copying: Bool
    let now: Date
    let actions: ClipboardActions
    private let hovering = State(initialValue: false)   // @State is a macro, unavailable without Xcode

    var body: some View {
        HStack(spacing: 8) {
            ClipboardIcon(item: item, size: 20)
            Text(item.previewLine)
                .font(NotchStyle.bodyFont)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if item.kind == .link && (hovering.wrappedValue || selected) {
                ClipboardChip(symbol: "safari", title: "Open", active: false) { actions.open(item) }
            }
            Text(ClipboardFormat.relative(item.copiedAt, now: now))
                .font(NotchStyle.smallFont)
                .monospacedDigit()
                .foregroundStyle(NotchStyle.tertiary)
            Button { actions.togglePin(item.id) } label: {
                Image(systemName: item.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(item.pinned ? Color.orange : NotchStyle.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(item.pinned || hovering.wrappedValue || selected ? 1 : 0)
            .help(item.pinned ? "Unpin (⌘P)" : "Pin (⌘P)")
            Text(index < 9 ? "⌘\(index + 1)" : "")
                .font(NotchStyle.monoFont)
                .foregroundStyle(NotchStyle.tertiary)
                .frame(width: 24, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(selected ? Color.white.opacity(0.14) : hovering.wrappedValue ? NotchStyle.card : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .opacity(copying ? 0.45 : 1)
        .contentShape(Rectangle())
        .onHover { hovering.wrappedValue = $0 }
        .onTapGesture { actions.copy(item) }
    }
}

/// The selected entry in full: text, link, image, files or color, with its buttons.
private struct ClipboardPreview: View {
    let item: ClipboardItem?
    let imageURL: URL?
    let now: Date
    let actions: ClipboardActions
    let isSnapshot: Bool

    var body: some View {
        Group {
            if let item {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(ClipboardFormat.title(item))
                            .font(NotchStyle.titleFont)
                            .foregroundStyle(.white)
                        Spacer(minLength: 4)
                        Text([item.source, ClipboardFormat.relative(item.copiedAt, now: now)]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(NotchStyle.smallFont)
                            .foregroundStyle(NotchStyle.tertiary)
                            .lineLimit(1)
                    }
                    content(item)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    buttons(item)
                }
            } else {
                Text("Nothing selected")
                    .font(NotchStyle.smallFont)
                    .foregroundStyle(NotchStyle.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(10)
        .frame(maxHeight: .infinity)
        .background(NotchStyle.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func content(_ item: ClipboardItem) -> some View {
        switch item.kind {
        case .text:
            VStack(alignment: .leading, spacing: 4) {
                Text(String(item.text.prefix(1200)))
                    .font(NotchStyle.bodyFont)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(6)
                Spacer(minLength: 0)
                detailLine(item)
            }
        case .link:
            VStack(alignment: .leading, spacing: 4) {
                Text(item.text)
                    .font(NotchStyle.bodyFont)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(5)
                Spacer(minLength: 0)
                detailLine(item)
            }
        case .image:
            VStack(alignment: .leading, spacing: 4) {
                ClipboardPreviewImage(item: item, url: isSnapshot ? nil : imageURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                detailLine(item)
            }
        case .files:
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(item.fileNames.prefix(4).enumerated()), id: \.offset) { _, name in
                    HStack(spacing: 6) {
                        Image(systemName: "doc")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(NotchStyle.secondary)
                        Text(name)
                            .font(NotchStyle.bodyFont)
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if item.fileNames.count > 4 {
                    Text("and \(item.fileNames.count - 4) more")
                        .font(NotchStyle.smallFont)
                        .foregroundStyle(NotchStyle.tertiary)
                }
                Spacer(minLength: 0)
                detailLine(item)
            }
        case .color:
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(item.color?.color ?? .clear)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.color?.hex ?? item.text)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                    detailLine(item)
                }
            }
        }
    }

    private func detailLine(_ item: ClipboardItem) -> some View {
        Text(ClipboardFormat.details(item))
            .font(NotchStyle.smallFont)
            .foregroundStyle(NotchStyle.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func buttons(_ item: ClipboardItem) -> some View {
        HStack(spacing: 6) {
            ClipboardChip(symbol: "doc.on.doc", title: "Copy", active: false) { actions.copy(item) }
                .help("Copy (Return)")
            if item.kind == .link {
                ClipboardChip(symbol: "safari", title: "Open", active: false) { actions.open(item) }
            } else if item.kind == .files {
                ClipboardChip(symbol: "folder", title: "Show", active: false) { actions.open(item) }
                    .help("Show in Finder")
            }
            Spacer(minLength: 0)
            ClipboardChip(symbol: item.pinned ? "pin.slash" : "pin", title: nil, active: item.pinned) {
                actions.togglePin(item.id)
            }
            .help(item.pinned ? "Unpin (⌘P)" : "Pin (⌘P)")
            ClipboardChip(symbol: "trash", title: nil, active: false) { actions.remove(item.id) }
                .help("Delete (⌘⌦, or ⌘⌫ when search is empty)")
        }
    }
}

/// An image entry: the thumbnail at once, then a sharper version read from its file.
private struct ClipboardPreviewImage: View {
    let item: ClipboardItem
    let url: URL?
    private let large = State<NSImage?>(initialValue: nil)
    private let largeID = State<UUID?>(initialValue: nil)

    var body: some View {
        Group {
            if let image = (largeID.wrappedValue == item.id ? large.wrappedValue : nil) ?? ClipboardThumbnailCache.image(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 24))
                    .foregroundStyle(NotchStyle.tertiary)
            }
        }
        .task(id: item.id) {
            guard let url else { return }
            let id = item.id
            let image = await Task.detached(priority: .userInitiated) {
                ClipboardWatcher.downsample(url, maxPixels: 520)
            }.value
            guard !Task.isCancelled, let image else { return }
            large.wrappedValue = NSImage(cgImage: image, size: .zero)
            largeID.wrappedValue = id
        }
    }
}

/// A small capsule button with an icon and an optional title.
private struct ClipboardChip: View {
    let symbol: String
    let title: String?
    let active: Bool
    let action: () -> Void
    private let hovering = State(initialValue: false)   // @State is a macro, unavailable without Xcode

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                if let title { Text(title).font(.system(size: 11, weight: .medium)) }
            }
            .padding(.horizontal, title == nil ? 6 : 8)
            .frame(height: 22)
            .foregroundStyle(active ? Color.orange : Color.white.opacity(0.85))
            .background(hovering.wrappedValue ? NotchStyle.cardHover : NotchStyle.card, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering.wrappedValue = $0 }
    }
}

/// A color swatch, an image thumbnail, or the kind's symbol.
struct ClipboardIcon: View {
    let item: ClipboardItem
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
        Group {
            if item.kind == .color, let c = item.color {
                shape.fill(c.color).overlay(shape.strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
            } else if item.kind == .image, let image = ClipboardThumbnailCache.image(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(shape)
            } else {
                Image(systemName: item.kind.symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(NotchStyle.secondary)
                    .frame(width: size, height: size)
                    .background(Color.white.opacity(0.08), in: shape)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: Home card

/// The last 5 copies; a click copies one again, the title opens the tab. While macOS keeps
/// history from reading copies, a line says so (and opens Settings) in place of the 5th.
struct ClipboardHomeCard: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var state: ClipboardViewState
    let actions: ClipboardActions

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: actions.showTab) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Clipboard")
                        .font(NotchStyle.titleFont)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(NotchStyle.tertiary)
                }
                .foregroundStyle(.white)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)

            if state.access != .allowed {
                Button(action: actions.openPrivacySettings) {
                    HStack(spacing: 4) {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text(state.access == .denied ? "Access is off" : "Paused by macOS")
                            .font(NotchStyle.smallFont)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Color.orange)
                    .frame(height: 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Set Paste from Other Apps to Always Allow in Privacy & Security")
            }
            if store.items.isEmpty {
                Text("Nothing copied yet")
                    .font(NotchStyle.smallFont)
                    .foregroundStyle(NotchStyle.secondary)
            }
            ForEach(store.items.prefix(state.access == .allowed ? 5 : 4)) { item in
                ClipboardCardRow(item: item, copying: item.id == state.copyingID) { actions.copy(item) }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ClipboardCardRow: View {
    let item: ClipboardItem
    let copying: Bool
    let action: () -> Void
    private let hovering = State(initialValue: false)   // @State is a macro, unavailable without Xcode

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ClipboardIcon(item: item, size: 16)
                Text(item.previewLine)
                    .font(NotchStyle.smallFont)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .frame(height: 23)
            .background(hovering.wrappedValue ? NotchStyle.cardHover : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(copying ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering.wrappedValue = $0 }
        .help("Copy")
    }
}
