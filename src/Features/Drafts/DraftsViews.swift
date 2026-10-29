import SwiftUI

/// Home card: the open-ask count, the 3 files with the most, and Quick Capture.
struct DraftsHomeCard: View {
    @ObservedObject var model: DraftsModel
    let actions: DraftsActions

    var body: some View {
        let summary = model.summary
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble")
                    .font(.system(size: 12, weight: .semibold))
                Text("Drafts")
                    .font(NotchStyle.titleFont)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.bottom, 4)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(summary.totalAsks)")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(summary.totalAsks > 0 ? Color.orange : Color.white)
                Text(summary.totalAsks == 1 ? "open ask" : "open asks")
                    .font(NotchStyle.smallFont)
                    .foregroundStyle(NotchStyle.secondary)
            }
            .padding(.bottom, 4)

            if summary.files.isEmpty {
                Text(emptyText(summary))
                    .font(NotchStyle.smallFont)
                    .foregroundStyle(NotchStyle.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(summary.files.prefix(3)) { file in
                DraftsFileRow(file: file) { actions.open(file) }
            }
            Spacer(minLength: 4)
            if actions.canCapture() {
                Button(action: actions.capture) {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                        Text("Quick Capture")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .background(Color.white.opacity(0.12), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Add a to-do to your Quick Capture file")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func emptyText(_ s: DraftsSummary) -> String {
        if !s.scanned { return "Looking…" }
        if s.roots.isEmpty { return s.fromSkim ? "Open a folder in skim to see its asks" : "No folders to scan" }
        return "Nothing waiting on you"
    }
}

/// One draft: its name and its ask count. Opens the file.
private struct DraftsFileRow: View {
    let file: DraftsFile
    let action: () -> Void
    private let hovering = State(initialValue: false)   // @State is a macro, unavailable without Xcode

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(file.name)
                    .font(NotchStyle.smallFont)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 2)
                Text("\(file.asks)")
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.2), in: Capsule())
            }
            .padding(.horizontal, 4)
            .frame(height: 21)
            .background(hovering.wrappedValue ? NotchStyle.cardHover : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering.wrappedValue = $0 }
        .help(file.path)
    }
}
