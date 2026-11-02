import Foundation
import Synchronization
import MainframeStatus
import SpacePushClient
@testable import SpaceStateCore
import Testing

actor Recorder {
    var alerts: [Alert] = []
    var lines: [String] = []
    func add(_ alert: Alert) { alerts.append(alert) }
    func add(_ line: String) { lines.append(line) }
}

struct DesktopServiceTests {
    static let mainframe = URL(string: "https://status.mainframe.io/api/spaceInfo")!
    let space = PushSubscription(endpoint: mainframe)

    func change(to state: String) -> ChangeFeedEvent {
        .change(StateChange(kind: .change, endpoint: Self.mainframe, room: "space", name: "Mainframe",
                            from: nil, to: state, at: Date()))
    }

    func service(_ events: [ChangeFeedEvent], failing error: (any Error)? = nil, readings: [String],
                 recorder: Recorder) -> DesktopService {
        let states = Mutex(readings)
        let topic = space
        return DesktopService(
            subscriptions: [space],
            events: {
                AsyncThrowingStream { continuation in
                    events.forEach { continuation.yield($0) }
                    continuation.finish(throwing: error)
                }
            },
            read: { _ in
                let state = states.withLock { $0.isEmpty ? nil : $0.removeFirst() }
                return state.map { [StateReader.Reading(topic: topic, name: "Mainframe", state: $0)] } ?? []
            },
            show: { await recorder.add($0) },
            log: { line in Task { await recorder.add(line) } })
    }

    @Test func resyncThenChanges() async {
        let recorder = Recorder()
        await service([.connected, change(to: "open"), change(to: "closed")], readings: ["closed"],
                      recorder: recorder).run()
        #expect(await recorder.alerts.map(\.body) == ["Open", "Closed"])
    }

    @Test func missedChangeIsShownAfterReconnect() async {
        let recorder = Recorder()
        let events: [ChangeFeedEvent] = [.connected, .disconnected(reason: "lost", retryIn: .seconds(1)),
                                         .connected, change(to: "open")]
        await service(events, readings: ["closed", "open"], recorder: recorder).run()
        // Shown once by the resync; the stream's later event repeats the same state.
        #expect(await recorder.alerts.map(\.body) == ["Open"])
    }

    @Test func trayFollowsTheConnectionAndChanges() async {
        let icons = Mutex<[TrayStatus.Icon]>([])
        let topic = space
        let service = DesktopService(
            subscriptions: [space],
            events: {
                AsyncThrowingStream { continuation in
                    continuation.yield(.connected)
                    continuation.yield(change(to: "open"))
                    continuation.yield(.disconnected(reason: "lost", retryIn: .seconds(1)))
                    continuation.finish()
                }
            },
            read: { _ in [StateReader.Reading(topic: topic, name: "Mainframe", state: "closed")] },
            show: { _ in },
            status: { status in icons.withLock { $0.append(status.icon) } },
            log: { _ in })
        await service.run()
        #expect(icons.withLock { $0 } == [.unknown, .closed, .open, .unknown, .unknown])
    }

    @Test func refusedStreamEndsTheRun() async {
        let recorder = Recorder()
        await service([], failing: SpacePushError.httpStatus(404, reason: "unknown_space"), readings: [],
                      recorder: recorder).run()
        #expect(await recorder.alerts.isEmpty)
    }

    @Test func nothingToFollow() async {
        let recorder = Recorder()
        let service = DesktopService(subscriptions: [], events: { AsyncThrowingStream { $0.finish() } },
                                     read: { _ in [] }, show: { await recorder.add($0) }, log: { _ in })
        await service.run()
        #expect(await recorder.alerts.isEmpty)
    }

    @Test func roomStatesUseTheStreamNames() {
        let room = PushSubscription(endpoint: Self.mainframe, room: "radstelle")
        let other = PushSubscription(endpoint: URL(string: "https://example.org/spaceapi.json")!, room: "radstelle")
        let rooms = [MainframeRoom(id: "radstelle", state: .openPlus, since: nil),
                     MainframeRoom(id: "lab3d", state: .unknown("odd"), since: nil)]
        #expect(StateReader.readings([room, other, PushSubscription(endpoint: Self.mainframe, room: "lab3d")], from: rooms)
            == [StateReader.Reading(topic: room, name: "Mainframe · Radstelle", state: "open_plus")])
    }
}
