import Foundation
import SpacePushClient

/// A notification to show. Its `id` is one per topic, so a newer one replaces the older.
public struct Alert: Sendable, Equatable {
    public var id: String
    public var summary: String
    public var body: String

    public init(id: String, summary: String, body: String) {
        self.id = id
        self.summary = summary
        self.body = body
    }

    /// The notification id of a space or room.
    public static func id(for topic: PushSubscription) -> String {
        "\(topic.endpoint.absoluteString)|\(topic.room ?? "space")"
    }
}

/// Translates a user-visible English text; the app passes gettext, tests the identity.
public typealias Translate = @Sendable (String) -> String

/// Notification texts, with the same meanings as the SpaceState apps' `PUSH_STATE_*` texts.
public struct AlertTexts: Sendable {
    let translate: Translate

    public init(translate: @escaping Translate = { $0 }) {
        self.translate = translate
    }

    public func describe(_ state: String) -> String {
        switch state {
        case "open": translate("Open")
        case "closed": translate("Closed")
        case "keyholder": translate("Keyholder present")
        case "member": translate("Open for members")
        case "open_plus": translate("Open+")
        case "closing": translate("Closing soon")
        default: state
        }
    }

    public var testBody: String {
        translate("Test notification from SpacePush. This is not a status change.")
    }
}

/// The last known state of each followed space and room, and what to notify.
public struct StateBoard: Sendable {
    public struct Entry: Sendable, Equatable {
        public var name: String
        /// A SpacePush state such as `"open"` or `"keyholder"`.
        public var state: String

        public init(name: String, state: String) {
            self.name = name
            self.state = state
        }
    }

    public private(set) var entries: [PushSubscription: Entry] = [:]
    let texts: AlertTexts

    public init(texts: AlertTexts = AlertTexts()) {
        self.texts = texts
    }

    /// A change from the stream. SpacePush sends only confirmed changes, but one
    /// can repeat a state a resync already saw; that one is not shown again.
    public mutating func apply(_ change: StateChange) -> Alert? {
        let topic = change.subscription
        let id = Alert.id(for: topic)
        guard change.kind == .change, let state = change.to else {
            return Alert(id: id, summary: change.name, body: texts.testBody)
        }
        let previous = entries[topic]
        entries[topic] = Entry(name: change.name, state: state)
        guard previous?.state != state else { return nil }
        return Alert(id: id, summary: change.name, body: texts.describe(state))
    }

    /// A state read after (re)connecting. The first reading of a topic is silent;
    /// a different state than before means a change was missed while disconnected.
    public mutating func resync(_ topic: PushSubscription, name: String, state: String) -> Alert? {
        let previous = entries[topic]
        entries[topic] = Entry(name: previous?.name ?? name, state: state)
        guard let previous, previous.state != state else { return nil }
        return Alert(id: Alert.id(for: topic), summary: previous.name, body: texts.describe(state))
    }

    /// Forgets topics that are no longer followed.
    public mutating func keep(only topics: [PushSubscription]) {
        let followed = Set(topics)
        entries = entries.filter { followed.contains($0.key) }
    }
}
