import Foundation
import SpacePushClient

/// What the tray icon shows: one icon for everything followed, and one line per topic.
public struct TrayStatus: Sendable, Equatable {
    public enum Icon: String, Sendable {
        case open, closed, unknown
    }

    public struct Line: Sendable, Equatable {
        public var name: String
        public var state: String
        /// A room listed under its space, which needs only the room's own name in the menu.
        public var indented: Bool

        public init(name: String, state: String, indented: Bool = false) {
            self.name = name
            self.state = state
            self.indented = indented
        }
    }

    public var icon: Icon
    public var lines: [Line]
    public var tooltip: String

    public init(icon: Icon, lines: [Line], tooltip: String) {
        self.icon = icon
        self.lines = lines
        self.tooltip = tooltip
    }

    /// Whether someone can get in, also when only keyholders or members can.
    /// A state only a newer server knows counts as neither.
    static func isOpen(_ state: String) -> Bool? {
        switch state {
        case "open", "open_plus", "keyholder", "member", "closing": true
        case "closed": false
        default: nil
        }
    }
}

extension StateBoard {
    /// The tray's view of the followed topics. While not connected the last states
    /// may be outdated, so they are shown as unknown; the board keeps them for the resync.
    public func trayStatus(following topics: [PushSubscription], connected: Bool,
                           name: (PushSubscription) -> String) -> TrayStatus {
        let unknown = texts.translate("Unknown")
        let known = connected ? topics.map { entries[$0]?.state } : topics.map { _ in nil }
        let lines = zip(topics, known).map { topic, state in
            TrayStatus.Line(name: entries[topic]?.name ?? name(topic), state: state.map(texts.describe) ?? unknown,
                            indented: topic.room != nil && topics.contains(PushSubscription(endpoint: topic.endpoint)))
        }
        let open = known.compactMap { $0.flatMap(TrayStatus.isOpen) }
        let icon: TrayStatus.Icon = open.contains(true) ? .open : open.isEmpty ? .unknown : .closed
        let tooltip = if topics.isEmpty {
            texts.translate("No spaces followed")
        } else if connected {
            lines.map { "\($0.name): \($0.state)" }.joined(separator: "\n")
        } else {
            texts.translate("Not connected")
        }
        return TrayStatus(icon: icon, lines: lines, tooltip: tooltip)
    }
}

/// The tray menu as data; the app hands it to the dbusmenu layer.
public struct TrayMenu: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public var id: Int32
        /// An empty label is a separator.
        public var label: String
        public var enabled: Bool

        public init(id: Int32, label: String, enabled: Bool) {
            self.id = id
            self.label = label
            self.enabled = enabled
        }
    }

    public static let settingsId: Int32 = 1
    public static let quitId: Int32 = 2

    public var items: [Item]

    public init(_ status: TrayStatus, settingsAvailable: Bool, texts: AlertTexts = AlertTexts()) {
        // Fixed ids come first, so ids stay unique however many lines there are.
        var lines = status.lines.enumerated().map { index, line in
            Item(id: Int32(index) + 100, label: Self.escaped(Self.label(of: line)), enabled: false)
        }
        if lines.isEmpty {
            lines = [Item(id: 100, label: texts.translate("No spaces followed"), enabled: false)]
        }
        items = lines + [
            Item(id: 3, label: "", enabled: true),
            Item(id: Self.settingsId, label: texts.translate("Settings…"), enabled: settingsAvailable),
            Item(id: 4, label: "", enabled: true),
            Item(id: Self.quitId, label: texts.translate("Quit"), enabled: true),
        ]
    }

    /// Rooms are titled "Mainframe · Radstelle"; under their space the room's name is enough.
    /// An em space indents, as hosts trim or collapse ordinary leading spaces.
    static func label(of line: TrayStatus.Line) -> String {
        guard line.indented else { return "\(line.name) — \(line.state)" }
        let room = line.name.components(separatedBy: " · ").last ?? line.name
        return "\u{2003}\(room) — \(line.state)"
    }

    /// In a dbusmenu label an underscore marks the access key, and a doubled one is literal.
    static func escaped(_ label: String) -> String {
        label.replacingOccurrences(of: "_", with: "__")
    }
}
