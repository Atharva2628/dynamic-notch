import AVFoundation
import Speech

/// Follows a speaker through the script: each new transcript is matched against the next
/// few dozen words, and a match moves the cursor past the last word said. Pure, so the
/// self-test can check it.
struct PrompterWordMatcher {
    private(set) var words: [String] = []        // normalized script words
    private(set) var offsets: [Int] = []         // UTF-16 offset of each word in the text
    private(set) var cursor = 0                  // index of the next word to be said
    private var lastTail: [String] = []

    static let lookBehind = 3
    static let lookAhead = 40

    init(text: String) {
        for token in Self.tokens(text) {
            words.append(token.word)
            offsets.append(token.offset)
        }
    }

    /// Where the last matched word starts, for scrolling it to the reading line.
    var spokenOffset: Int { words.isEmpty ? 0 : offsets[min(max(cursor - 1, 0), offsets.count - 1)] }

    /// Feeds the transcript so far. Only its last four words count: the last must match a
    /// script word near the cursor, and at least one more must match the words before it
    /// (two more for a jump of over a dozen words). A lone heard word moves the cursor only
    /// when it is long and just ahead. Never moves backward. Returns true when it moved.
    mutating func advance(heard transcript: String) -> Bool {
        let tail = Array(Self.tokens(transcript).map(\.word).suffix(4))
        guard let last = tail.last, tail != lastTail, !words.isEmpty else { return false }
        lastTail = tail
        let lo = max(0, cursor - Self.lookBehind), hi = min(words.count - 1, cursor + Self.lookAhead)
        guard lo <= hi else { return false }
        var best: (score: Int, index: Int)?
        for j in lo...hi where Self.same(last, words[j]) {
            var score = 1
            for t in 1..<max(tail.count, 1) where j - t >= 0 {
                if Self.same(tail[tail.count - 1 - t], words[j - t]) { score += 1 }
            }
            if tail.count == 1 {
                guard words[j].count >= 4, j >= cursor, j <= cursor + 3 else { continue }
            } else {
                guard score >= (j > cursor + 12 ? 3 : 2) else { continue }
            }
            if let b = best, score < b.score || (score == b.score && abs(j - cursor) >= abs(b.index - cursor)) { continue }
            best = (score, j)
        }
        guard let best, best.index + 1 > cursor else { return false }
        cursor = best.index + 1
        return true
    }

    /// Puts the cursor at the first word at or after `offset` (the text was scrolled by hand).
    mutating func seek(toOffset offset: Int) {
        cursor = offsets.firstIndex { $0 >= offset } ?? words.count
        lastTail = []
    }

    /// Lowercase, without accents or apostrophes: "Don't" → "dont", "Café," → "cafe".
    static func normalize(_ word: some StringProtocol) -> String {
        String(word).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Words split at spaces and punctuation (apostrophes stay inside), with their UTF-16 offsets.
    static func tokens(_ text: String) -> [(word: String, offset: Int)] {
        var out: [(String, Int)] = []
        var current = ""
        var start = 0, offset = 0
        func flush() {
            let w = normalize(current)
            if !w.isEmpty { out.append((w, start)) }
            current = ""
        }
        for ch in text {
            if ch.isLetter || ch.isNumber || ch == "'" || ch == "’" {
                if current.isEmpty { start = offset }
                current.append(ch)
            } else if !current.isEmpty {
                flush()
            }
            offset += ch.utf16.count
        }
        if !current.isEmpty { flush() }
        return out
    }

    /// Equal, or close enough for a recognizer: a shared stem of 4+ letters ("pitch",
    /// "pitching") or one letter off in a word of 5+.
    static func same(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let shorter = min(a.count, b.count)
        if shorter >= 4 && (a.hasPrefix(b) || b.hasPrefix(a)) { return true }
        return shorter >= 5 && abs(a.count - b.count) <= 1 && editDistance(Array(a), Array(b), limit: 1) <= 1
    }

    /// Levenshtein distance, giving up once every path exceeds `limit`.
    private static func editDistance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var row = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            if (row.min() ?? 0) > limit { return limit + 1 }
            previous = row
        }
        return previous[b.count]
    }
}

/// On-device speech recognition for voice follow: the microphone through AVAudioEngine into
/// SFSpeechRecognizer, never the network. Asks for Speech Recognition and Microphone access
/// the first time it starts (only when you turn voice follow on and press Start).
///
/// Limitations: needs on-device recognition for the Mac's language (installed with
/// Dictation); recognition runs in segments that restart on silence or after about a
/// minute; numbers and names may be heard differently than written, so the scroll waits
/// until the next words match.
@MainActor
final class PrompterVoiceFollower {
    var onTranscript: ((String) -> Void)?
    var onState: ((PrompterVoiceState) -> Void)?

    private var recognizer: SFSpeechRecognizer?
    private var engine: AVAudioEngine?
    private var audioObserver: NSObjectProtocol?
    private var audioRestartPending = false      // merges a burst of device-change notices
    private var task: SFSpeechRecognitionTask?
    private let sink = PrompterAudioSink()
    private var active = false
    private var generation = 0
    private var restarts: [Date] = []
    private var contextualStrings: [String] = []

    /// Starts listening, asking for permission first if needed. `script` supplies a few
    /// unusual words to help the recognizer.
    func start(script: String) {
        guard !active else { return }
        active = true
        contextualStrings = Self.hints(from: script)
        onState?(.starting)
        Self.requestSpeech { [weak self] granted in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.speechAnswered(granted) }
            }
        }
    }

    func stop() {
        guard active else { return }
        active = false
        generation += 1
        teardown()
    }

    private func speechAnswered(_ granted: Bool) {
        guard active else { return }
        guard granted else {
            fail("Speech Recognition is off for Dynamic Notch (Privacy & Security)")
            return
        }
        Self.requestMicrophone { [weak self] granted in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.microphoneAnswered(granted) }
            }
        }
    }

    private func microphoneAnswered(_ granted: Bool) {
        guard active else { return }
        guard granted else {
            fail("Microphone is off for Dynamic Notch (Privacy & Security)")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            fail("Speech recognition isn't available right now")
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            fail("On-device speech isn't installed for this language; turn on Dictation once to get it")
            return
        }
        self.recognizer = recognizer
        if let reason = startAudio() {
            fail(reason)
            return
        }
        beginSegment()
        onState?(.listening)
        PrompterLog.logger.info("voice follow listening")
    }

    /// A new engine tapping the current input device, in the device's current format.
    /// Returns why it couldn't start, or nil when it's running.
    private func startAudio() -> String? {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return "No microphone found" }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(sink))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            PrompterLog.logger.error("audio engine: \(error.localizedDescription, privacy: .public)")
            return "The microphone didn't start"
        }
        self.engine = engine
        // The engine stops itself when the input device or its format changes. The notice
        // comes on an internal queue that must not wait for us, so it only hops to main.
        let id = ObjectIdentifier(engine)
        audioObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil,
            using: Self.configurationChanged { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.audioChanged(id) }
                }
            })
        return nil
    }

    private func stopAudio() {
        if let audioObserver { NotificationCenter.default.removeObserver(audioObserver) }
        audioObserver = nil
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
    }

    /// The microphone changed (another device, or a new sample rate) and the engine stopped.
    /// Waits for the device to settle, then listens on a new engine: the old input node's
    /// format is stale, and a request takes one format, so the segment starts over too.
    private func audioChanged(_ id: ObjectIdentifier) {
        guard active, let engine, ObjectIdentifier(engine) == id, !audioRestartPending else { return }
        audioRestartPending = true
        PrompterLog.logger.info("voice follow: the microphone changed")
        restartAudio(triesLeft: 3)
    }

    private func restartAudio(triesLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated { self?.restartAudioNow(triesLeft: triesLeft) }
        }
    }

    private func restartAudioNow(triesLeft: Int) {
        guard active, audioRestartPending else { return }
        generation += 1                          // the old task's results are ignored
        sink.set(nil)
        task?.cancel()
        task = nil
        stopAudio()
        if startAudio() != nil {
            // A device that is still switching reports no format for a moment.
            if triesLeft > 1 { restartAudio(triesLeft: triesLeft - 1) } else { fail("The microphone changed") }
            return
        }
        audioRestartPending = false
        restarts = []
        beginSegment()
    }

    /// One recognition request. A new one starts whenever the last ends (silence, time limit).
    private func beginSegment() {
        guard active, let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = contextualStrings
        sink.set(request)
        generation += 1
        let current = generation
        task = recognizer.recognitionTask(with: request, resultHandler: Self.results { [weak self] text, ended in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.received(text, ended: ended, generation: current) }
            }
        })
    }

    private func received(_ text: String?, ended: Bool, generation current: Int) {
        guard active, current == generation else { return }
        if let text, !text.isEmpty { onTranscript?(text) }
        guard ended else { return }
        // Restart, unless it keeps ending at once (recognizer broken or unavailable).
        let now = Date()
        restarts = restarts.filter { now.timeIntervalSince($0) < 20 } + [now]
        guard restarts.count <= 8 else {
            fail("Speech recognition keeps stopping")
            return
        }
        sink.set(nil)
        task = nil
        // The engine stopped without a notice: start a new one, which starts the segment.
        if let engine, !engine.isRunning {
            audioChanged(ObjectIdentifier(engine))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.active, current == self.generation else { return }
                self.beginSegment()
            }
        }
    }

    private func fail(_ reason: String) {
        PrompterLog.logger.info("voice follow off: \(reason, privacy: .public)")
        active = false
        generation += 1
        teardown()
        onState?(.failed(reason))
    }

    private func teardown() {
        sink.set(nil)
        task?.cancel()
        task = nil
        stopAudio()
        audioRestartPending = false
        recognizer = nil
        restarts = []
    }

    /// Up to 50 distinct long words from the script, which the recognizer might not expect.
    static func hints(from script: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for word in script.split(whereSeparator: { !$0.isLetter && $0 != "'" }) where word.count >= 7 {
            let key = word.lowercased()
            if seen.insert(key).inserted { out.append(String(word)) }
            if out.count == 50 { break }
        }
        return out
    }

    // Callbacks built outside the main actor: the system calls them on its own threads.

    nonisolated private static func requestSpeech(_ done: @escaping @Sendable (Bool) -> Void) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: done(true)
        case .notDetermined: SFSpeechRecognizer.requestAuthorization { done($0 == .authorized) }
        default: done(false)
        }
    }

    nonisolated private static func requestMicrophone(_ done: @escaping @Sendable (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { done($0) }
        default: done(false)
        }
    }

    nonisolated private static func tap(_ sink: PrompterAudioSink) -> AVAudioNodeTapBlock {
        { buffer, _ in sink.append(buffer) }
    }

    nonisolated private static func configurationChanged(_ deliver: @escaping @Sendable () -> Void)
        -> @Sendable (Notification) -> Void {
        { _ in deliver() }
    }

    nonisolated private static func results(_ deliver: @escaping @Sendable (String?, Bool) -> Void)
        -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            deliver(result?.bestTranscription.formattedString, error != nil || result?.isFinal == true)
        }
    }
}

/// Hands microphone buffers from the audio thread to the current recognition request.
private final class PrompterAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ new: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        let old = request
        request = new
        lock.unlock()
        if old !== new { old?.endAudio() }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = request
        lock.unlock()
        current?.append(buffer)
    }
}
