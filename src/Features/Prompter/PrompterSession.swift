import AppKit
import SwiftUI

/// Scroll arithmetic for the prompter strip. The text starts with its first line on the
/// reading line and ends when its last line has passed it, so the scroll distance is the
/// text's height. Pure, so the self-test can check it.
enum PrompterScrollMath {
    /// 0...1 through the script.
    static func progress(position: CGFloat, contentHeight: CGFloat) -> Double {
        guard contentHeight > 0 else { return 0 }
        return Double(min(max(position / contentHeight, 0), 1))
    }

    /// Seconds left to speak the rest, at the configured words per minute.
    static func timeLeft(words: Int, progress: Double, wordsPerMinute: Double) -> TimeInterval {
        PrompterText.duration(words: words, wordsPerMinute: wordsPerMinute) * (1 - min(max(progress, 0), 1))
    }

    /// One frame of steady scrolling.
    static func advanced(_ position: CGFloat, speed: Double, dt: Double, contentHeight: CGFloat) -> CGFloat {
        clamp(position + CGFloat(speed * max(0, dt)), contentHeight: contentHeight)
    }

    /// One frame of easing toward a target (voice follow): covers about 95% of the gap per second.
    static func eased(_ position: CGFloat, toward target: CGFloat, dt: Double, contentHeight: CGFloat) -> CGFloat {
        let k = CGFloat(min(1, max(0, dt) * 3))
        return clamp(position + (target - position) * k, contentHeight: contentHeight)
    }

    /// Keeps the place in the script when the text reflows (font size or width changed).
    static func rescaled(_ position: CGFloat, from old: CGFloat, to new: CGFloat) -> CGFloat {
        guard old > 0, new > 0 else { return 0 }
        return position / old * new
    }

    static func clamp(_ position: CGFloat, contentHeight: CGFloat) -> CGFloat {
        min(max(position, 0), max(0, contentHeight))
    }

    /// Where the strip goes. With a notch, the strip is the notch grown downward: one black
    /// shape from the top of the screen, `height` of text below the notch's row, and never
    /// narrower than the notch's ears, so the two read as one. Without a notch (lid closed),
    /// centered under the menu bar of `fallback`, the main screen's visible frame. Kept on
    /// the screen.
    static func windowFrame(notch: NotchGeometry?, fallback: CGRect, width: CGFloat, height: CGFloat) -> CGRect {
        if let g = notch {
            let ears = NotchMetrics(notch: g.notchSize, panel: .zero).frame(.compact).width
            let w = min(max(width, ears), g.screenFrame.width)
            let x = min(max(g.centerX - w / 2, g.screenFrame.minX), g.screenFrame.maxX - w)
            let h = g.notchSize.height + height
            return CGRect(x: x, y: g.top - h, width: w, height: h)
        }
        let x = min(max(fallback.midX - width / 2, fallback.minX), fallback.maxX - width)
        return CGRect(x: x, y: fallback.maxY - height, width: width, height: height)
    }
}

/// Where each laid-out line of the script starts, from TextKit, so voice follow can bring
/// a spoken word to the reading line. Offsets are UTF-16, as NSString counts.
struct PrompterLineMap {
    var lineStarts: [Int] = []
    var lineTops: [CGFloat] = []
    var height: CGFloat = 0

    static func lineSpacing(fontSize: Double) -> CGFloat { CGFloat(fontSize * 0.3) }
    static func font(size: Double) -> NSFont { NSFont.systemFont(ofSize: CGFloat(size), weight: .medium) }

    static func make(text: String, fontSize: Double, width: CGFloat) -> PrompterLineMap {
        guard width > 0, !text.isEmpty else { return PrompterLineMap() }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing(fontSize: fontSize)
        let storage = NSTextStorage(string: text, attributes: [.font: font(size: fontSize), .paragraphStyle: style])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        var map = PrompterLineMap()
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { rect, _, _, glyphs, _ in
            map.lineStarts.append(layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil).location)
            map.lineTops.append(rect.minY)
        }
        map.height = layout.usedRect(for: container).height
        return map
    }

    /// The top of the line holding `offset`.
    func top(forOffset offset: Int) -> CGFloat {
        guard !lineStarts.isEmpty else { return 0 }
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lineTops[lo]
    }

    /// The first character of the line at `y`.
    func offset(atY y: CGFloat) -> Int {
        guard let i = lineTops.lastIndex(where: { $0 <= y }) else { return lineStarts.first ?? 0 }
        return lineStarts[i]
    }
}

enum PrompterVoiceState: Equatable {
    case off
    case starting                 // asking for permission, loading the recognizer
    case listening
    case failed(String)           // why; scrolling falls back to the set speed
}

/// One run of the prompter: the countdown, the scroll position, pauses and speed. Driven by
/// the window's display link through `tick(_:)` while something moves.
@MainActor
final class PrompterSession: ObservableObject {
    enum Phase: Equatable { case countdown, running, finished }

    static let countdownSeconds = 3.0
    static let stripHeight: CGFloat = 170
    static let readingLine: CGFloat = 38         // the line being read sits this far from the top
    static let autoCloseAfter = 6.0              // seconds the finished strip stays up
    static let speedStep = 5.0
    static let fontStep = 2.0

    let scriptID: String
    let title: String
    let plain: String                            // the characters shown, for voice follow
    let text: AttributedString
    let words: Int

    @Published private(set) var phase: Phase = .countdown
    @Published private(set) var countdown = PrompterSession.countdownSeconds
    @Published private(set) var position: CGFloat = 0
    @Published private(set) var contentHeight: CGFloat = 0
    @Published var speed: Double
    @Published var fontSize: Double { didSet { if fontSize != oldValue { lineMap = nil } } }
    @Published var wordsPerMinute: Double
    @Published var userPaused = false
    @Published var hoverPaused = false
    @Published var notchHeld = false             // the open notch or a peek covers the strip
    @Published var voice: PrompterVoiceState
    @Published private(set) var flash: String?

    private var textWidth: CGFloat = 0
    private var finishedFor = 0.0
    private var matcher: PrompterWordMatcher
    private var lineMap: PrompterLineMap?
    private var voiceTarget: CGFloat?
    private var flashWork: DispatchWorkItem?

    init(script: PrompterScript, speed: Double, fontSize: Double, wordsPerMinute: Double, followVoice: Bool) {
        scriptID = script.id
        title = script.title
        text = PrompterText.attributed(script.display)
        plain = String(text.characters)
        words = PrompterText.wordCount(plain)
        self.speed = speed
        self.fontSize = fontSize
        self.wordsPerMinute = wordsPerMinute
        voice = followVoice ? .starting : .off
        matcher = PrompterWordMatcher(text: plain)
    }

    var progress: Double { PrompterScrollMath.progress(position: position, contentHeight: contentHeight) }
    var timeLeft: TimeInterval {
        PrompterScrollMath.timeLeft(words: words, progress: progress, wordsPerMinute: wordsPerMinute)
    }

    /// Voice drives the scroll while it's starting or listening; otherwise the set speed does.
    var followsVoice: Bool { voice == .starting || voice == .listening }

    /// Paused by Space, by the pointer resting on the strip, or while the notch covers it.
    var isHeld: Bool { userPaused || hoverPaused || notchHeld }

    /// Whether the display link needs to run: only while something moves or counts down.
    var needsFrames: Bool {
        switch phase {
        case .countdown: return !userPaused
        case .finished: return !isHeld
        case .running:
            guard !isHeld else { return false }
            guard contentHeight > 0, followsVoice else { return true }   // keeps ticking until the text is measured
            return voiceTarget.map { abs($0 - position) > 0.5 } ?? false
        }
    }

    /// Advances by `dt` seconds. Returns true once the finished strip has stayed up long enough.
    @discardableResult
    func tick(_ dt: Double) -> Bool {
        switch phase {
        case .countdown:
            guard !userPaused else { return false }
            countdown = max(0, countdown - dt)
            if countdown <= 0 { phase = .running }
        case .running:
            guard !isHeld, contentHeight > 0 else { return false }
            if followsVoice {
                if let target = voiceTarget {
                    let next = PrompterScrollMath.eased(position, toward: target, dt: dt, contentHeight: contentHeight)
                    position = abs(target - next) < 0.5 ? PrompterScrollMath.clamp(target, contentHeight: contentHeight) : next
                }
            } else {
                position = PrompterScrollMath.advanced(position, speed: speed, dt: dt, contentHeight: contentHeight)
            }
            if position >= contentHeight {
                phase = .finished
                finishedFor = 0
            }
        case .finished:
            guard !isHeld else { return false }
            finishedFor += dt
            return finishedFor >= Self.autoCloseAfter
        }
        return false
    }

    /// Space: pauses and resumes; on the finished strip, plays it again from the top.
    func togglePause() {
        if phase == .finished {
            restart()
        } else {
            userPaused.toggle()
            show(userPaused ? "Paused" : "Playing")
        }
    }

    func restart() {
        position = 0
        phase = .countdown
        countdown = Self.countdownSeconds
        userPaused = false
        finishedFor = 0
        matcher.seek(toOffset: 0)
        voiceTarget = nil
    }

    /// Moves the text by `delta` points (arrow keys, scroll wheel). Voice follow picks up
    /// from the new place.
    func seek(by delta: CGFloat) {
        guard contentHeight > 0 else { return }
        if phase == .countdown {
            phase = .running
            countdown = 0
        }
        position = PrompterScrollMath.clamp(position + delta, contentHeight: contentHeight)
        // Seeking to the end finishes the run now: with voice follow nothing would tick it there.
        phase = position < contentHeight ? .running : .finished
        finishedFor = 0
        if followsVoice, let map = currentLineMap() {
            let scale = map.height > 0 ? contentHeight / map.height : 1
            matcher.seek(toOffset: map.offset(atY: position / max(scale, 0.0001)))
            voiceTarget = position
        }
    }

    /// Three lines, for the left and right arrow keys.
    var lineStep: CGFloat { CGFloat(fontSize * 1.2) * 3 + PrompterLineMap.lineSpacing(fontSize: fontSize) * 3 }

    func changeSpeed(by delta: Double) {
        speed = min(max(speed + delta, 5), 300)
        show("Speed \(Int(speed.rounded()))")
    }

    func changeFontSize(by delta: Double) {
        fontSize = min(max(fontSize + delta, 10), 60)
        show("Size \(Int(fontSize.rounded())) pt")
    }

    /// The strip measured the text: keeps the place when it reflows.
    func layoutChanged(width: CGFloat, height: CGFloat) {
        if width != textWidth {
            textWidth = width
            lineMap = nil
        }
        guard height != contentHeight else { return }
        if contentHeight > 0 {
            position = PrompterScrollMath.rescaled(position, from: contentHeight, to: height)
            voiceTarget = voiceTarget.map { PrompterScrollMath.rescaled($0, from: contentHeight, to: height) }
        }
        contentHeight = height
        lineMap = nil
    }

    /// For snapshots: a fixed place without measuring or ticking.
    func setForSnapshot(phase: Phase, position: CGFloat, contentHeight: CGFloat, countdown: Double = 0) {
        self.phase = phase
        self.position = position
        self.contentHeight = contentHeight
        self.countdown = countdown
    }

    // MARK: Voice

    /// The recognizer's transcript so far. Moves the target when it matches the next words
    /// of the script. Returns true when the target moved.
    @discardableResult
    func heard(_ transcript: String) -> Bool {
        guard phase == .running, matcher.advance(heard: transcript), let map = currentLineMap() else { return false }
        let scale = map.height > 0 ? contentHeight / map.height : 1
        // The last word said scrolls to the end, which finishes the run.
        let target = matcher.cursor >= matcher.words.count ? contentHeight : map.top(forOffset: matcher.spokenOffset) * scale
        guard target != voiceTarget else { return false }
        voiceTarget = PrompterScrollMath.clamp(target, contentHeight: contentHeight)
        return true
    }

    private func currentLineMap() -> PrompterLineMap? {
        if lineMap == nil, textWidth > 0 {
            lineMap = PrompterLineMap.make(text: plain, fontSize: fontSize, width: textWidth)
        }
        return lineMap
    }

    // MARK: Flash

    /// A short note in the strip's corner ("Speed 45").
    func show(_ note: String) {
        flash = note
        flashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flash = nil }
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }
}
