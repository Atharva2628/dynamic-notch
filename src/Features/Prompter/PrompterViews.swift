import AppKit
import SwiftUI

/// What the tab shows besides the scripts: the settings it edits, whether the prompter is
/// running, and a short note (import results, errors). Kept in step with the config by
/// the feature.
@MainActor
final class PrompterTabState: ObservableObject {
    @Published var speed: Double = 40
    @Published var fontSize: Double = 20
    @Published var wordsPerMinute: Double = 150
    @Published var voiceFollow = false
    @Published var runningID: String?
    @Published private(set) var notice: String?
    private var noticeWork: DispatchWorkItem?

    func say(_ text: String) {
        notice = text
        noticeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.notice = nil }
        }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }
}

/// What the tab's buttons do. No-ops by default (snapshots).
struct PrompterActions {
    var start: (PrompterScript) -> Void = { _ in }
    var stop: () -> Void = {}
    var newScript: () -> Void = {}
    var openFolder: () -> Void = {}
    var edit: (PrompterScript) -> Void = { _ in }
    var reveal: (PrompterScript) -> Void = { _ in }
    var importNotchy: () -> Void = {}
    var setSpeed: (Double) -> Void = { _ in }
    var setFontSize: (Double) -> Void = { _ in }
    var setVoiceFollow: (Bool) -> Void = { _ in }
}

/// The Prompter tab: scripts on the left, the selected one's preview in the middle, Start
/// and the settings on the right.
struct PrompterTabView: View {
    @ObservedObject var library: PrompterLibrary
    @ObservedObject var state: PrompterTabState
    let actions: PrompterActions
    /// Off for snapshots, which can't draw scroll views.
    var scrolls = true

    var body: some View {
        let selected = library.selected
        HStack(spacing: 12) {
            scriptList(selected: selected)
                .frame(width: 222)
            preview(selected)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            controls(selected)
                .frame(width: 172)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: List

    private func scriptList(selected: PrompterScript?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Scripts").font(NotchStyle.titleFont).foregroundStyle(.white)
                Text("\(library.scripts.count)")
                    .font(NotchStyle.smallFont).monospacedDigit().foregroundStyle(NotchStyle.tertiary)
                Spacer(minLength: 0)
                PrompterIconButton(symbol: "plus", help: "New Script", action: actions.newScript)
                PrompterIconButton(symbol: "folder", help: "Open Folder", action: actions.openFolder)
            }
            .frame(height: 22)
            if library.scripts.isEmpty {
                emptyList
            } else if scrolls {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) { rows(selected: selected) }
                        .onChange(of: library.selectedID) { _, id in
                            if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                        }
                }
            } else {
                rows(selected: selected)
                Spacer(minLength: 0)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Lazy in the scroll view; plain for snapshots.
    @ViewBuilder private func rows(selected: PrompterScript?) -> some View {
        if scrolls {
            LazyVStack(spacing: 2) { ForEach(library.scripts) { row($0, selected: selected) } }
        } else {
            VStack(spacing: 2) { ForEach(library.scripts) { row($0, selected: selected) } }
        }
    }

    private func row(_ script: PrompterScript, selected: PrompterScript?) -> some View {
        PrompterRow(script: script, selected: script.id == selected?.id,
                    running: script.id == state.runningID, wordsPerMinute: state.wordsPerMinute)
            .id(script.id)
            .onTapGesture { library.select(script) }
            .contextMenu {
                Button("Start") { actions.start(script) }
                Button("Edit") { actions.edit(script) }
                Button("Show in Finder") { actions.reveal(script) }
            }
    }

    private var emptyList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(library.loaded ? "No scripts yet." : "Reading scripts…")
                .font(NotchStyle.bodyFont).foregroundStyle(NotchStyle.secondary)
            if library.loaded {
                PrompterPillButton(title: "New Script", symbol: "square.and.pencil", action: actions.newScript)
                PrompterPillButton(title: "Import from Notchy", symbol: "square.and.arrow.down", action: actions.importNotchy)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    // MARK: Preview

    private func preview(_ script: PrompterScript?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let script {
                HStack(spacing: 6) {
                    Text(script.title).font(NotchStyle.titleFont).foregroundStyle(.white).lineLimit(1)
                    Spacer(minLength: 0)
                    PrompterIconButton(symbol: "square.and.pencil", help: "Edit in your text editor") { actions.edit(script) }
                }
                Text(Self.summary(script, wordsPerMinute: state.wordsPerMinute))
                    .font(NotchStyle.smallFont).monospacedDigit().foregroundStyle(NotchStyle.tertiary)
                Text(PrompterText.attributed(PrompterText.preview(Self.withoutTitle(script))))
                    .font(NotchStyle.bodyFont)
                    .foregroundStyle(NotchStyle.secondary)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0.75), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    .padding(.top, 2)
            } else {
                Text("Your scripts").font(NotchStyle.titleFont).foregroundStyle(.white)
                Text("Plain .md or .txt files in \(Self.shortPath(library.folder)). Add one here or in Finder.")
                    .font(NotchStyle.bodyFont).foregroundStyle(NotchStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if let notice = state.notice {
                Text(notice).font(NotchStyle.smallFont).foregroundStyle(Color.orange).lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NotchStyle.card, in: RoundedRectangle(cornerRadius: NotchStyle.cornerRadius, style: .continuous))
    }

    // MARK: Controls

    private func controls(_ script: PrompterScript?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if state.runningID != nil {
                PrompterStartButton(title: "Stop", symbol: "stop.fill", tint: Color(red: 1, green: 0.36, blue: 0.33),
                                    enabled: true, action: actions.stop)
            } else {
                PrompterStartButton(title: "Start", symbol: "play.fill", tint: .white,
                                    enabled: (script?.words ?? 0) > 0) { if let script { actions.start(script) } }
            }
            PrompterStepper(label: "Speed", value: "\(Int(state.speed.rounded()))", unit: "pt/s",
                            minus: { actions.setSpeed(state.speed - PrompterSession.speedStep) },
                            plus: { actions.setSpeed(state.speed + PrompterSession.speedStep) })
            PrompterStepper(label: "Size", value: "\(Int(state.fontSize.rounded()))", unit: "pt",
                            minus: { actions.setFontSize(state.fontSize - PrompterSession.fontStep) },
                            plus: { actions.setFontSize(state.fontSize + PrompterSession.fontStep) })
            PrompterSwitchRow(label: "Follow my voice", isOn: state.voiceFollow) { actions.setVoiceFollow(!state.voiceFollow) }
            Spacer(minLength: 0)
            Text("Space pauses · ↑↓ speed\n⌘+ ⌘− size · Esc stops")
                .font(.system(size: 10)).foregroundStyle(NotchStyle.tertiary).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    static func summary(_ script: PrompterScript, wordsPerMinute: Double) -> String {
        let time = PrompterText.clock(PrompterText.duration(words: script.words, wordsPerMinute: wordsPerMinute))
        return "\(script.words.formatted()) words · about \(time) at \(Int(wordsPerMinute)) wpm"
    }

    /// The text without a first line that only repeats the file's title (a `# Title` heading).
    static func withoutTitle(_ script: PrompterScript) -> String {
        let lines = script.display.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard lines.count == 2, lines[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(script.title) == .orderedSame
        else { return script.display }
        return String(lines[1]).trimmingCharacters(in: .newlines)
    }

    /// "~/Library/…/DynamicNotch/Prompter" style.
    static func shortPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: Pieces

private struct PrompterRow: View {
    let script: PrompterScript
    let selected: Bool
    let running: Bool
    let wordsPerMinute: Double
    private let hovering = State(initialValue: false)   // @State is a macro, unavailable without Xcode

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: running ? "play.circle.fill" : "doc.text")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(running ? Color.green : NotchStyle.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(script.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text("\(script.words.formatted()) words · \(PrompterText.clock(PrompterText.duration(words: script.words, wordsPerMinute: wordsPerMinute)))")
                    .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(NotchStyle.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(selected ? NotchStyle.cardHover : (hovering.wrappedValue ? NotchStyle.card : Color.clear),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering.wrappedValue = $0 }
    }
}

private struct PrompterIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NotchStyle.secondary)
                .frame(width: 24, height: 22)
                .background(NotchStyle.card, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct PrompterPillButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(NotchStyle.cardHover, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct PrompterStartButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Color.black)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(tint.opacity(enabled ? 1 : 0.3), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(title == "Start" ? "Start the prompter (Return)" : "Stop the prompter (Esc)")
    }
}

private struct PrompterStepper: View {
    let label: String
    let value: String
    let unit: String
    let minus: () -> Void
    let plus: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(NotchStyle.bodyFont).foregroundStyle(NotchStyle.secondary)
            Spacer(minLength: 0)
            step("minus", minus)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                Text(unit).font(.system(size: 9.5)).foregroundStyle(NotchStyle.tertiary)
            }
            .frame(width: 50)
            step("plus", plus)
        }
        .frame(height: 24)
    }

    private func step(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(NotchStyle.card, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// A switch drawn in SwiftUI (the AppKit one can't be rendered in snapshots).
private struct PrompterSwitchRow: View {
    let label: String
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Text(label).font(NotchStyle.bodyFont).foregroundStyle(NotchStyle.secondary)
                Spacer(minLength: 0)
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? Color.green : Color.white.opacity(0.18))
                    Circle().fill(Color.white).padding(2)
                }
                .frame(width: 30, height: 18)
                .animation(.easeOut(duration: 0.15), value: isOn)
            }
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Scrolls as you speak, recognized on this Mac. Asks for Microphone and Speech Recognition when you start.")
    }
}
