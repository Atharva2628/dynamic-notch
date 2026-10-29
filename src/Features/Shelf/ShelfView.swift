import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What the Shelf's buttons do. The feature passes live ones; snapshots keep the no-ops.
struct ShelfActions {
    var airDrop: @MainActor ([URL]) -> Void = { _ in }
    var copy: @MainActor ([URL]) -> Void = { _ in }
    var reveal: @MainActor ([URL]) -> Void = { _ in }
    var open: @MainActor (URL) -> Void = { _ in }
    /// A tile was clicked; the feature lets the panel take ⌘A from then on.
    var tileClicked: @MainActor () -> Void = {}
}

/// The Shelf tab: a header with the actions over a grid of tiles, or the empty state.
struct ShelfTabView: View {
    @ObservedObject var store: ShelfStore
    var actions = ShelfActions()
    /// Off for snapshots, which can't draw a scroll view.
    var scrolls = true

    // Plain State values, not the @State macro: the Command Line Tools have no SwiftUI
    // macro plugin. SwiftUI finds them the same way.
    private let targeted = State(initialValue: false)
    private let panelTargeted = State(initialValue: false)
    private let copied = State(initialValue: false)

    private static let columns = [GridItem(.adaptive(minimum: 80, maximum: 104), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.items.isEmpty {
                emptyState
            } else {
                header
                grid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: targeted.projectedValue) { store.addDropped($0) }
        .background { panelDropTarget }
        .overlay { if targeted.wrappedValue || panelTargeted.wrappedValue { dropHighlight } }
        .focusEffectDisabled()
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Shelf")
                .font(NotchStyle.titleFont)
                .foregroundStyle(.white)
            Text(status)
                .font(NotchStyle.smallFont)
                .monospacedDigit()
                .foregroundStyle(NotchStyle.secondary)
            if store.items.count > 1 {
                Button(store.selection.isEmpty ? "Select All" : "Deselect") {
                    if store.selection.isEmpty { store.selectAll() } else { store.deselectAll() }
                }
                .buttonStyle(.plain)
                .font(NotchStyle.smallFont)
                .foregroundStyle(NotchStyle.tertiary)
            }
            Spacer(minLength: 8)
            let urls = targetURLs
            ShelfActionButton(title: "AirDrop", symbol: "dot.radiowaves.left.and.right", enabled: !urls.isEmpty) {
                actions.airDrop(urls)
            }
            ShelfActionButton(title: copied.wrappedValue ? "Copied" : "Copy",
                              symbol: copied.wrappedValue ? "checkmark" : "doc.on.doc", enabled: !urls.isEmpty) {
                guard !urls.isEmpty else { return }
                actions.copy(urls)
                flashCopied()
            }
            ShelfActionButton(title: "Show in Finder", symbol: "folder", enabled: !urls.isEmpty) {
                actions.reveal(urls)
            }
            if store.selection.isEmpty {
                ShelfActionButton(title: "Clear", symbol: "xmark.circle") { store.clear() }
            } else {
                ShelfActionButton(title: "Remove", symbol: "minus.circle") { store.remove(store.selection.ids) }
            }
        }
        .frame(height: 22)
    }

    /// Says what the actions work on: everything, or the selection, and how many of those
    /// are on a drive that isn't connected (AirDrop, Copy and Show in Finder skip them).
    private var status: String {
        let n = store.items.count
        let base = store.selection.isEmpty ? (n == 1 ? "1 item" : "\(n) items")
            : "\(store.selection.count) of \(n) selected"
        let away = store.targets.count - store.actionable.count
        return away > 0 ? "\(base), \(away) offline" : base
    }

    private var targetURLs: [URL] { store.actionable.map(\.url) }

    private func flashCopied() {
        let copied = self.copied
        copied.wrappedValue = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            copied.wrappedValue = false
        }
    }

    // MARK: Tiles

    @ViewBuilder
    private var grid: some View {
        if scrolls {
            ScrollView(.vertical, showsIndicators: false) { tiles }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            tiles.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var tiles: some View {
        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 8) {
            ForEach(store.items) { item in
                let offline = store.offline.contains(item.id)
                ShelfTile(name: item.name, icon: store.icon(for: item), thumbnail: store.thumbnails[item.id],
                          selected: store.selection.contains(item.id), offline: offline)
                    .onTapGesture {
                        store.toggle(item.id)
                        actions.tileClicked()
                    }
                    .shelfDrag(offline ? nil : item.url)
                    .contextMenu { menu(for: item, offline: offline) }
                    .help(item.path)
                    .onAppear { store.requestThumbnail(for: item) }
            }
        }
    }

    /// A file on a drive that isn't connected can only be removed.
    @ViewBuilder
    private func menu(for item: ShelfItem, offline: Bool) -> some View {
        Group {
            Button("Open") { actions.open(item.url) }
            Button("Show in Finder") { actions.reveal([item.url]) }
            Button("Copy") { actions.copy([item.url]) }
            Button("AirDrop") { actions.airDrop([item.url]) }
        }
        .disabled(offline)
        Divider()
        Button("Remove from Shelf") { store.remove([item.id]) }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            Text("Drop files on the notch")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Text("They stay where they are. Drag them out anywhere.")
                .font(NotchStyle.bodyFont)
                .foregroundStyle(NotchStyle.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Dropping

    /// While a file drag is on its way, the whole open panel takes the drop, tab icons and
    /// margins included: this reaches past the tab body on every side and lights the
    /// highlight. The window takes the pointer only inside the panel, so the overhang never
    /// catches anything else, and it's off the rest of the time so it never blocks the tab
    /// icons; the panel's own drop target (model.panelDrop) still lands those drops here.
    private var panelDropTarget: some View {
        Color.clear
            .contentShape(Rectangle())
            .onDrop(of: [.fileURL], isTargeted: panelTargeted.projectedValue) { store.addDropped($0) }
            .allowsHitTesting(store.dragInProgress)
            .padding(EdgeInsets(top: -64, leading: -40, bottom: -40, trailing: -40))
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: NotchStyle.cornerRadius, style: .continuous)
            .strokeBorder(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .background(Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: NotchStyle.cornerRadius, style: .continuous))
            .allowsHitTesting(false)
    }
}

/// One file: its preview or Finder icon, and its name. Selected tiles get a tint and a check.
struct ShelfTile: View {
    let name: String
    let icon: NSImage
    let thumbnail: NSImage?
    let selected: Bool
    let offline: Bool

    private let hovering = State(initialValue: false)
    private static let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: thumbnail ?? icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: thumbnail == nil ? 0 : 5, style: .continuous))
            Text(name)
                .font(NotchStyle.smallFont)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(fill, in: Self.shape)
        .overlay {
            if selected { Self.shape.strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1.5) }
        }
        .overlay(alignment: .topTrailing) {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(4)
            }
        }
        .opacity(offline ? 0.45 : 1)
        .contentShape(Self.shape)
        .onHover { hovering.wrappedValue = $0 }
    }

    private var fill: Color {
        if selected { return Color.accentColor.opacity(0.28) }
        return hovering.wrappedValue ? NotchStyle.cardHover : NotchStyle.card
    }
}

/// A small capsule button in the Shelf header, like the peek's buttons.
struct ShelfActionButton: View {
    let title: String
    let symbol: String
    var enabled = true
    let action: () -> Void

    private let hovering = State(initialValue: false)

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .foregroundStyle(.white)
                .background(Color.white.opacity(enabled && hovering.wrappedValue ? 0.22 : 0.14), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering.wrappedValue = $0 }
    }
}

private extension View {
    /// Lets a tile be dragged out as its file; nil (a file on a drive that isn't connected)
    /// leaves it in place.
    @ViewBuilder
    func shelfDrag(_ url: URL?) -> some View {
        if let url {
            onDrag { NSItemProvider(object: url as NSURL) }
        } else {
            self
        }
    }
}
