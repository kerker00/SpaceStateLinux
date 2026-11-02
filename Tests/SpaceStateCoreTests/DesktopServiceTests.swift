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
            events: { _ in
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
            events: { _ in
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

    @Test func anUnavailableStreamFallsBackToReading() async {
        let recorder = Recorder()
        let icons = Mutex<[TrayStatus.Icon]>([])
        let reads = Mutex(0)
        let states = Mutex(["closed", "open"])
        let topic = space
        let service = DesktopService(
            subscriptions: [space],
            events: { _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(.disconnected(reason: "503", retryIn: .seconds(1)))
                    continuation.yield(.disconnected(reason: "503", retryIn: .seconds(30)))
                    continuation.yield(.disconnected(reason: "503", retryIn: .seconds(60)))
                    continuation.yield(.disconnected(reason: "503", retryIn: .seconds(120)))
                    continuation.finish()
                }
            },
            read: { _ in
                reads.withLock { $0 += 1 }
                let state = states.withLock { $0.isEmpty ? nil : $0.removeFirst() }
                return state.map { [StateReader.Reading(topic: topic, name: "Mainframe", state: $0)] } ?? []
            },
            show: { await recorder.add($0) },
            status: { status in icons.withLock { $0.append(status.icon) } },
            log: { _ in })
        await service.run()
        // A short wait does not read. A change seen by reading is notified. When reading
        // fails too, the state is unknown again.
        #expect(reads.withLock { $0 } == 3)
        #expect(await recorder.alerts.map(\.body) == ["Open"])
        #expect(icons.withLock { $0 } == [.unknown, .unknown, .closed, .open, .unknown, .unknown])
    }

    @Test func onlyChosenTopicsNotifyButAllAreListed() async {
        let recorder = Recorder()
        let chosen = PushSubscription(endpoint: Self.mainframe, room: "radstelle")
        let other = PushSubscription(endpoint: Self.mainframe, room: "lab3d")
        let lines = Mutex<[[TrayStatus.Line]]>([])
        let opened = Mutex<[[PushSubscription]]>([])
        func roomChange(_ room: String, to state: String) -> ChangeFeedEvent {
            .change(StateChange(kind: .change, endpoint: Self.mainframe, room: room, name: "Mainframe · \(room)",
                                from: nil, to: state, at: Date()))
        }
        let events = [ChangeFeedEvent.connected, roomChange("lab3d", to: "open"), roomChange("radstelle", to: "open")]
        let service = DesktopService(
            subscriptions: [chosen],
            topics: { [chosen, other] },
            events: { topics in
                opened.withLock { $0.append(topics) }
                return AsyncThrowingStream { continuation in
                    events.forEach { continuation.yield($0) }
                    continuation.finish()
                }
            },
            read: { _ in
                [StateReader.Reading(topic: chosen, name: "Mainframe · radstelle", state: "closed"),
                 StateReader.Reading(topic: other, name: "Mainframe · lab3d", state: "closed")]
            },
            show: { await recorder.add($0) },
            status: { status in lines.withLock { $0.append(status.lines) } },
            log: { _ in })
        await service.run()
        #expect(opened.withLock { $0 } == [[chosen, other]])
        #expect(await recorder.alerts.map(\.summary) == ["Mainframe · radstelle"])
        #expect(lines.withLock { $0.last?.map(\.state) } == ["Unknown", "Unknown"])
        #expect(lines.withLock { $0.contains { $0.map(\.state) == ["Open", "Open"] } })
    }

    @Test func learningTheRoomsIsRetriedThenGivenUp() async {
        let chosen = PushSubscription(endpoint: Self.mainframe, room: "radstelle")
        let attempts = Mutex(0)
        let waits = Mutex<[Duration]>([])
        let opened = Mutex<[[PushSubscription]]>([])
        let lines = Recorder()
        func service(failures: Int) -> DesktopService {
            DesktopService(
                subscriptions: [chosen],
                topics: {
                    let attempt = attempts.withLock { $0 += 1; return $0 }
                    if attempt <= failures { throw URLError(.notConnectedToInternet) }
                    return [chosen, PushSubscription(endpoint: Self.mainframe, room: "lab3d")]
                },
                events: { topics in
                    opened.withLock { $0.append(topics) }
                    return AsyncThrowingStream { $0.finish() }
                },
                read: { _ in [] }, show: { _ in },
                sleep: { duration in waits.withLock { $0.append(duration) } },
                log: { line in Task { await lines.add(line) } })
        }
        await service(failures: 2).run()
        #expect(waits.withLock { $0 } == [.seconds(5), .seconds(10)])
        #expect(opened.withLock { $0.last?.count } == 2)
        attempts.withLock { $0 = 0 }
        waits.withLock { $0 = [] }
        await service(failures: 99).run()
        #expect(waits.withLock { $0 } == [.seconds(5), .seconds(10), .seconds(20), .seconds(40)])
        #expect(opened.withLock { $0.last } == [chosen])
    }

    @Test func aRefusedStreamKeepsNotifyingByReading() async {
        let recorder = Recorder()
        let icons = Mutex<[TrayStatus.Icon]>([])
        let waits = Mutex<[Duration]>([])
        let states = Mutex(["closed", "open"])
        let topic = space
        let service = DesktopService(
            subscriptions: [space],
            events: { _ in AsyncThrowingStream { $0.finish(throwing: SpacePushError.httpStatus(404, reason: "unknown_space")) } },
            read: { _ in
                let state = states.withLock { $0.isEmpty ? nil : $0.removeFirst() }
                return state.map { [StateReader.Reading(topic: topic, name: "Mainframe", state: $0)] } ?? []
            },
            show: { await recorder.add($0) },
            status: { status in icons.withLock { $0.append(status.icon) } },
            sleep: { duration in
                let count = waits.withLock { $0.append(duration); return $0.count }
                if count == 3 { throw CancellationError() }
            },
            log: { _ in })
        await service.run()
        #expect(await recorder.alerts.map(\.body) == ["Open"])
        #expect(icons.withLock { $0 } == [.unknown, .closed, .open, .unknown])
        #expect(waits.withLock { $0 } == Array(repeating: DesktopService.refusedReadingInterval, count: 3))
    }

    @Test func nothingToFollow() async {
        let recorder = Recorder()
        let service = DesktopService(subscriptions: [], events: { _ in AsyncThrowingStream { $0.finish() } },
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
