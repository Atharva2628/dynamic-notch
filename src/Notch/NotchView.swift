import SwiftUI

/// Everything inside the notch window: the black shape at the top center and what's in it.
struct NotchRootView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        if let metrics = model.metrics {
            let mode = model.mode
            let size = metrics.frame(mode)
            let shape = NotchShape(fillet: NotchMetrics.fillet(mode), bottomRadius: metrics.bottomRadius(mode))
            ZStack(alignment: .top) {
                shape
                    .fill(Color.black)
                    .shadow(color: .black.opacity(mode == .open || mode == .peek ? 0.4 : 0), radius: 12, y: 6)
                NotchContent(model: model, mode: mode, metrics: metrics)
                    .padding(.horizontal, NotchMetrics.fillet(mode))
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .clipShape(shape)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(shape)
            .onTapGesture { if !model.isOpen { model.openFromClick() } }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.spring(response: 0.36, dampingFraction: 0.82), value: mode)
            .environment(\.colorScheme, .dark)
        } else {
            Color.clear
        }
    }
}

private struct NotchContent: View {
    @ObservedObject var model: NotchModel
    let mode: NotchMode
    let metrics: NotchMetrics

    var body: some View {
        let top = model.shownActivity
        Group {
            switch mode {
            case .idle, .hover:
                Color.clear
            case .compact:
                EarsRow(activity: top, notchWidth: metrics.notch.width)
                    .frame(height: metrics.notch.height)
            case .peek:
                VStack(spacing: 0) {
                    EarsRow(activity: top, notchWidth: metrics.notch.width)
                        .frame(height: metrics.notch.height)
                    if let top { PeekDetail(activity: top, activities: model.activities) }
                }
            case .open:
                OpenPanel(model: model, notch: metrics.notch)
            }
        }
        .transition(.opacity)
    }
}

/// The left ear holds the activity's icon, the right ear its accessory; the middle sits
/// behind the hardware notch.
private struct EarsRow: View {
    let activity: Activity?
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let activity {
                    if let image = activity.image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 20, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    } else {
                        Image(systemName: activity.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(activity.tint.color)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 14)

            Color.clear.frame(width: notchWidth)

            Group {
                switch activity?.accessory ?? .none {
                case .none: EmptyView()
                case .text(let text):
                    Text(text)
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .allowsTightening(true)
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(activity?.tint.color ?? .white)
                case .animatedSymbol(let name):
                    Image(systemName: name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(activity?.tint.color ?? .white)
                        .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
                case .progress(let fraction):
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.2), lineWidth: 2.5)
                        Circle().trim(from: 0, to: max(0, min(1, fraction)))
                            .stroke(activity?.tint.color ?? .white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 14, height: 14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 14)
        }
    }
}

private struct PeekDetail: View {
    let activity: Activity
    let activities: ActivityCenter

    var body: some View {
        VStack(spacing: 8) {
            if let url = activity.fileURL {
                summary.onDrag { NSItemProvider(object: url as NSURL) }
            } else {
                summary
            }
            if let detail = activity.detail {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.horizontal, 16)
                    .textSelection(.enabled)
            }
            if !activity.actions.isEmpty {
                // Redraws while any button is still arming, then stops.
                TimelineView(.periodic(from: .now, by: 0.2)) { timeline in
                HStack(spacing: 8) {
                    ForEach(activity.actions) { action in
                        let armed = timeline.date.timeIntervalSince(activity.postedAt) >= action.armDelay
                        Button { if armed { activities.perform(activityID: activity.id, actionID: action.id) } } label: {
                            Group {
                                if let symbol = action.symbol {
                                    Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                                } else {
                                    Text(action.title)
                                        .font(.system(size: 12, weight: .semibold))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.85)
                                }
                            }
                                .opacity(armed ? 1 : 0.45)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .foregroundStyle(action.style == .primary ? Color.black : Color.white)
                                .background(background(action.style), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(!armed)
                    }
                }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
    }

    private func background(_ style: ActivityAction.Style) -> Color {
        switch style {
        case .primary: .white
        case .destructive: .red.opacity(0.8)
        case .normal: .white.opacity(0.16)
        }
    }

    private var summary: some View {
        HStack(spacing: 12) {
            Group {
                if let image = activity.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                } else {
                    Image(systemName: activity.symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(activity.tint.color)
                        .frame(width: 28)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                if let subtitle = activity.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, activity.detail == nil ? 0 : 8)
        .frame(maxHeight: activity.detail == nil ? .infinity : nil)
    }
}
