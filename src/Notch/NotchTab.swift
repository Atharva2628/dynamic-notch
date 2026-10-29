import Foundation

/// The open panel's tabs. Placeholders say which milestone fills them in.
enum NotchTab: String, CaseIterable, Identifiable, Codable {
    case home, terminal, agents, system, calendar, clipboard, shelf, prompter, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .terminal: "Terminal"
        case .agents: "Agents"
        case .system: "System"
        case .calendar: "Calendar"
        case .clipboard: "Clipboard"
        case .shelf: "Shelf"
        case .prompter: "Prompter"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .terminal: "terminal.fill"
        case .agents: "sparkles"
        case .system: "cpu"
        case .calendar: "calendar"
        case .clipboard: "doc.on.clipboard"
        case .shelf: "tray.full.fill"
        case .prompter: "text.aligncenter"
        case .settings: "gearshape.fill"
        }
    }

    /// The milestone that builds this tab (from SPEC.md).
    var milestone: String {
        switch self {
        case .home, .settings: "M0"
        case .terminal: "M1"
        case .agents: "M2"
        case .clipboard, .shelf: "M3"
        case .system, .calendar: "M4"
        case .prompter: "M5"
        }
    }

    var blurb: String {
        switch self {
        case .home: "Agents, system, calendar and clipboard at a glance."
        case .terminal: "Your shell, with tabs, also in the menu bar."
        case .agents: "Claude sessions, permission requests and usage limits."
        case .system: "CPU, GPU, memory, SSD, network, battery and heat."
        case .calendar: "Today, the next 7 days, and a Join button for meetings."
        case .clipboard: "The last 40 copies plus pins, searchable."
        case .shelf: "Drop files here, drag them out anywhere."
        case .prompter: "Scrolls your script right under the camera."
        case .settings: "Notch size, timing and tabs."
        }
    }
}
