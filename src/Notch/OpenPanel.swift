import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The open notch: tab icons on both sides of the hardware notch, the tab below.
struct OpenPanel: View {
    @ObservedObject var model: NotchModel
    let notch: CGSize

    var body: some View {
        let tabs = model.visibleTabs
        let split = (tabs.count + 1) / 2
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                TabStrip(tabs: Array(tabs.prefix(split)), selection: model.currentTab) { model.select($0) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 14)
                Color.clear.frame(width: notch.width + 16)
                TabStrip(tabs: Array(tabs.dropFirst(split)), selection: model.currentTab) { model.select($0) }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 14)
            }
            .frame(height: notch.height)

            TabBody(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 16)
        }
        // Files dropped anywhere on the panel, including the tab row and margins, go to
        // the current tab if it takes drops (the shelf); other tabs refuse them.
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], delegate: PanelDropDelegate(model: model))
    }
}

private struct TabStrip: View {
    let tabs: [NotchTab]
    let selection: NotchTab
    let select: (NotchTab) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                Button { select(tab) } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 30, height: 22)
                        .foregroundStyle(tab == selection ? Color.white : Color.white.opacity(0.45))
                        .background(tab == selection ? Color.white.opacity(0.14) : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(tab.title)
            }
        }
    }
}

private struct TabBody: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        let tab = model.currentTab
        if let make = model.tabViews[tab] {
            make()
        } else {
            switch tab {
            case .home: HomeTab(model: model)
            case .settings: SettingsTab(model: model)
            default: Placeholder(tab: tab)
            }
        }
    }
}

private struct HomeTab: View {
    @ObservedObject var model: NotchModel
    private let cards: [NotchTab] = [.agents, .system, .calendar, .clipboard]

    var body: some View {
        if !model.homeCards.isEmpty {
            HStack(spacing: 10) {
                ForEach(model.homeCards.indices, id: \.self) { i in
                    model.homeCards[i]()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        } else {
            placeholders
        }
    }

    private var placeholders: some View {
        HStack(spacing: 10) {
            ForEach(cards) { tab in
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer(minLength: 0)
                    Text(tab.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Arrives in \(tab.milestone)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
}

private struct Placeholder: View {
    let tab: NotchTab

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: tab.symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            Text(tab.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Text(tab.blurb)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
            Text("Arrives in \(tab.milestone)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SettingsTab: View {
    @ObservedObject var model: NotchModel

    private let switches: [(String, WritableKeyPath<Config, Bool>)] = [
        ("Peek on hover", \.hoverToPeek),
        ("Approve Claude requests here", \.agentApprovals),
        ("Cost at API prices", \.apiCostEstimate),
        ("Calendar", \.calendarEnabled),
        ("Caps Lock flash", \.capsLockHUD),
        ("Camera indicator", \.cameraGuard),
        ("Microphone indicator", \.micGuard),
        ("Unlock animation", \.lockNotice),
        ("Downloads", \.downloads),
        ("Now playing", \.nowPlaying),
        ("Hide music when paused", \.nowPlayingHideWhenPaused),
        ("Stats beside the notch", \.statsInEars),
        ("Clipboard auto-paste", \.clipboardAutoPaste),
        ("Prompter follows your voice", \.prompterVoiceFollow),
        ("Agent Away status", \.agentAwayStatus),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                row("Notch", model.geometry.map { "\(Int($0.notchSize.width)) × \(Int($0.notchSize.height)) pt" } ?? "not found")
                row("Terminal", model.config.terminalHotkey)
                row("Clipboard", model.config.clipboardHotkey)
                row("Quick Capture", model.config.quickCaptureHotkey.isEmpty ? "off" : model.config.quickCaptureHotkey)
                row("Version", Bundle.main.version)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Button("Settings file") { NSWorkspace.shared.open(Config.fileURL) }
                    Button("Reload") { model.reloadConfig() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(width: 230, alignment: .leading)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                    toggle("Claude usage limits", Binding(
                        get: { model.config.usageSource == "keychain" },
                        set: { on in model.updateConfig { $0.usageSource = on ? "keychain" : "off" } }))
                    ForEach(switches.indices, id: \.self) { i in
                        let (title, key) = switches[i]
                        toggle(title, Binding(get: { model.config[keyPath: key] },
                                              set: { on in model.updateConfig { $0[keyPath: key] = on } }))
                    }
                }
            }
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func toggle(_ title: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            Text(title).foregroundStyle(.white).lineLimit(1)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.white.opacity(0.5)).frame(width: 96, alignment: .leading)
            Text(value).foregroundStyle(.white).lineLimit(1)
        }
    }
}

/// Accepts file drops only while the current tab has a drop handler.
private struct PanelDropDelegate: DropDelegate {
    let model: NotchModel

    func validateDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { model.panelDrop[model.currentTab] != nil } && info.hasItemsConforming(to: [.fileURL])
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { model.panelDrop[model.currentTab]?(info.itemProviders(for: [.fileURL])) ?? false }
    }
}
