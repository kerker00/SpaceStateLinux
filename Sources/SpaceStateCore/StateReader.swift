import Foundation
import MainframeStatus
import SpaceAPI
import SpacePushClient

/// Reads the current states through the read API, for the resync after each connection.
public enum StateReader {
    public struct Reading: Sendable, Equatable {
        public var topic: PushSubscription
        public var name: String
        public var state: String

        public init(topic: PushSubscription, name: String, state: String) {
            self.topic = topic
            self.name = name
            self.state = state
        }
    }

    /// Returns the states it could read; a topic that fails or is unknown is left out.
    public typealias Read = @Sendable ([PushSubscription]) async -> [Reading]

    public static func live(_ service: StatusService, log: @escaping @Sendable (String) -> Void) -> Read {
        { topics in
            await withTaskGroup(of: [Reading].self) { group in
                for topic in topics where topic.room == nil {
                    group.addTask {
                        do {
                            let space = try await service.space(at: topic.endpoint)
                            guard let state = state(of: space.status) else { return [] }
                            return [Reading(topic: topic, name: space.name, state: state)]
                        } catch {
                            log("Could not read \(topic.endpoint.absoluteString): \(error)")
                            return []
                        }
                    }
                }
                let rooms = topics.filter { $0.room != nil }
                if !rooms.isEmpty {
                    group.addTask {
                        do {
                            return readings(rooms, from: try await service.mainframeRooms())
                        } catch {
                            log("Could not read the Mainframe rooms: \(error)")
                            return []
                        }
                    }
                }
                return await group.reduce(into: []) { $0 += $1 }
            }
        }
    }

    /// Rooms exist only at Mainframe; SpacePush titles them "Mainframe · Room".
    static func readings(_ topics: [PushSubscription], from rooms: [MainframeRoom]) -> [Reading] {
        topics.compactMap { topic in
            guard Mainframe.isMainframe(topic.endpoint),
                  let room = rooms.first(where: { $0.id == topic.room }),
                  let state = state(of: room.state) else { return nil }
            return Reading(topic: topic, name: "Mainframe · \(room.name)", state: state)
        }
    }

    static func state(of status: SpaceStatus) -> String? {
        switch status {
        case .open: "open"
        case .closed: "closed"
        case .unknown: nil
        }
    }

    /// The names SpacePush uses for Mainframe room states in its stream.
    static func state(of room: MainframeRoomState) -> String? {
        switch room {
        case .closed: "closed"
        case .keyholder: "keyholder"
        case .member: "member"
        case .open: "open"
        case .openPlus: "open_plus"
        case .closing: "closing"
        case .unknown: nil
        }
    }
}
