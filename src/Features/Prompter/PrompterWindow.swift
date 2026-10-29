import AppKit
import QuartzCore
import SwiftUI

/// The prompter strip's window: borderless, black, under the notch on every Space
/// (fullscreen ones too), and kept out of screenshots and screen sharing. It takes keys
/// without activating the app, so the app you record in stays in front.
final class PrompterPanel: NSPanel {
    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 420, height: PrompterSession.stripHeight),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosts the strip: takes the first click, reports the pointer resting on it (hover pauses)
/// and turns the scroll wheel into seeking.
final class PrompterHostingView: NSHostingView<PrompterStripView> {
    var onHover: ((Bool) -> Void)?
    var onScroll: ((CGFloat) -> Void)?
    private var area: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let new = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                 owner: self, userInfo: nil)
        addTrackingArea(new)
        area = new
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === area { onHover?(true) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === area { onHover?(false) }
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        onScroll?(-dy)
    }
}

/// Shows and hides the strip, places it under the notch, and runs the display link while
/// the session has something to animate (never while paused or hidden).
@MainActor
final class PrompterWindowController: NSObject {
    let panel = PrompterPanel()
    private(set) var session: PrompterSession?
    private var host: PrompterHostingView?
    private var topInset: CGFloat = 0
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?

    /// Every frame, after the session moved (the feature updates the activity).
    var onFrame: (() -> Void)?
    /// The finished strip has stayed up long enough.
    var onAutoClose: (() -> Void)?

    var isShown: Bool { session != nil }

    func show(_ session: PrompterSession, frame: CGRect, topInset: CGFloat) {
        stopLink()
        self.session = session
        self.topInset = topInset
        let host = PrompterHostingView(rootView: PrompterStripView(session: session, topInset: topInset))
        host.sizingOptions = []
        host.onHover = { [weak self] inside in self?.hover(inside) }
        host.onScroll = { [weak self] delta in self?.scroll(delta) }
        self.host = host
        panel.contentView = host
        panel.setFrame(frame, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        updateLink()
    }

    func hide() {
        stopLink()
        session = nil
        host?.onHover = nil
        host?.onScroll = nil
        host = nil
        let panel = panel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.session == nil else { return }
                self.panel.orderOut(nil)
                self.panel.contentView = nil
            }
        })
    }

    func place(_ frame: CGRect, topInset: CGFloat) {
        guard isShown, let session else { return }
        if topInset != self.topInset {
            self.topInset = topInset
            host?.rootView = PrompterStripView(session: session, topInset: topInset)
        }
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: true)
    }

    /// Starts or stops the display link to match what the session needs.
    func updateLink() {
        let wants = session?.needsFrames ?? false
        if wants && link == nil, let host {
            let l = host.displayLink(target: self, selector: #selector(step(_:)))
            l.add(to: .main, forMode: .common)
            link = l
            lastTimestamp = nil
        } else if !wants {
            stopLink()
        }
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
        lastTimestamp = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let session else {
            stopLink()
            return
        }
        let now = link.timestamp
        let dt = lastTimestamp.map { min(0.1, max(0, now - $0)) } ?? 0
        lastTimestamp = now
        let close = session.tick(dt)
        onFrame?()
        if close {
            onAutoClose?()
            return
        }
        updateLink()
    }

    private func hover(_ inside: Bool) {
        guard let session, session.hoverPaused != inside else { return }
        session.hoverPaused = inside
        onFrame?()
        updateLink()
    }

    private func scroll(_ delta: CGFloat) {
        guard let session else { return }
        session.seek(by: delta)
        onFrame?()
        updateLink()
    }
}

// MARK: Strip

/// The strip under the notch: the script scrolling past a reading line near the camera,
/// faded at the top and bottom, with the countdown, progress and time left.
struct PrompterStripView: View {
    @ObservedObject var session: PrompterSession
    /// The notch's row at the top of the strip: left black, for the notch and its ears.
    var topInset: CGFloat = 0

    /// The same top curve as the notch, so the two meet without a seam.
    static let fillet: CGFloat = NotchMetrics.fillet(.peek)
    static let topFade: CGFloat = 26
    static let bottomFade: CGFloat = 44

    var body: some View {
        let shape = NotchShape(fillet: Self.fillet, bottomRadius: 20)
        ZStack(alignment: .top) {
            shape.fill(Color.black)
            PrompterScrollingText(session: session)
                .padding(.horizontal, Self.fillet + 22)
                .mask(fade)
                .opacity(session.phase == .countdown ? 0.3 : 1)
                .padding(.top, topInset)
            if session.phase == .countdown {
                Text("\(Int(session.countdown.rounded(.up)))")
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, topInset)
            } else if session.phase == .finished {
                VStack(spacing: 4) {
                    Text("The End").font(.system(size: 20, weight: .semibold))
                    Text("Space plays it again · Esc closes").font(NotchStyle.smallFont).foregroundStyle(NotchStyle.secondary)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.6))
                .padding(.top, topInset)
            }
            footer
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .clipShape(shape)
        .environment(\.colorScheme, .dark)
    }

    private var fade: some View {
        GeometryReader { geo in
            let h = max(geo.size.height, 1)
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: Self.topFade / h),
                .init(color: .black, location: 1 - Self.bottomFade / h),
                .init(color: .clear, location: 1 - 12 / h),
            ], startPoint: .top, endPoint: .bottom)
        }
    }

    private var footer: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                voiceBadge
                Text(status)
                    .foregroundStyle(session.isHeld && session.phase == .running ? Color.orange : NotchStyle.tertiary)
                Spacer(minLength: 4)
                if let flash = session.flash {
                    Text(flash).foregroundStyle(NotchStyle.secondary)
                }
            }
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.14))
                    Capsule().fill(Color.white.opacity(0.75))
                        .frame(width: max(2, geo.size.width * session.progress))
                }
            }
            .frame(height: 2)
        }
        .padding(.horizontal, Self.fillet + 22)
        .padding(.bottom, 9)
    }

    @ViewBuilder private var voiceBadge: some View {
        switch session.voice {
        case .off: EmptyView()
        case .starting: Image(systemName: "mic").foregroundStyle(NotchStyle.tertiary)
        case .listening: Image(systemName: "mic.fill").foregroundStyle(Color.green)
        case .failed: Image(systemName: "mic.slash").foregroundStyle(Color.orange)
        }
    }

    private var status: String {
        let left = "\(PrompterText.clock(session.timeLeft)) left"
        switch session.phase {
        case .countdown: return session.userPaused ? "Paused" : "Starting"
        case .finished: return "Finished"
        case .running:
            if session.userPaused { return "Paused · \(left)" }
            if session.hoverPaused { return "Paused while the pointer is here" }
            if session.notchHeld { return "Paused while the notch is open" }
            return left
        }
    }
}

/// The text block, moved by the scroll position. The block itself is equatable, so the
/// per-frame redraw only moves it.
private struct PrompterScrollingText: View {
    @ObservedObject var session: PrompterSession

    var body: some View {
        PrompterTextBlock(text: session.text, fontSize: session.fontSize)
            .equatable()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                session.layoutChanged(width: size.width, height: size.height)
            }
            .offset(y: PrompterSession.readingLine - session.position)
            // minHeight 0: without it the frame grows to the whole text's height.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
            .clipped()
    }
}

private struct PrompterTextBlock: View, Equatable {
    let text: AttributedString
    let fontSize: Double

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .medium))
            .lineSpacing(PrompterLineMap.lineSpacing(fontSize: fontSize))
            .foregroundStyle(.white)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
