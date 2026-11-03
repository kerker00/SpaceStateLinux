import Foundation
import SpacePushClient
import SpaceStateCore
import Testing

struct TrayStatusTests {
    static let mainframe = URL(string: "https://status.mainframe.io/api/spaceInfo")!
    let space = PushSubscription(endpoint: mainframe)
    let room = PushSubscription(endpoint: mainframe, room: "radstelle")

    func board(_ states: [(PushSubscription, String)]) -> StateBoard {
        var board = StateBoard()
        for (topic, state) in states { _ = board.resync(topic, name: "Name of \(topic.room ?? "space")", state: state) }
        return board
    }

    func status(_ states: [(PushSubscription, String)], connected: Bool = true) -> TrayStatus {
        board(states).trayStatus(following: [space, room], connected: connected, name: { _ in "Fallback" })
    }

    @Test func anyOpenTopicShowsOpen() {
        #expect(status([(space, "closed"), (room, "keyholder")]).icon == .open)
        #expect(status([(room, "closing")]).icon == .open)
    }

    @Test func closedNeedsAKnownClosedTopicAndNoOpenOne() {
        #expect(status([(space, "closed"), (room, "closed")]).icon == .closed)
        #expect(status([(space, "closed")]).icon == .closed)
        #expect(status([]).icon == .unknown)
    }

    @Test func unrecognisedStatesCountAsUnknownButKeepTheirText() {
        let status = status([(space, "party")])
        #expect(status.icon == .unknown)
        #expect(status.lines[0].state == "party")
    }

    @Test func linesFollowTheTopicOrderAndFallBackToTheName() {
        let status = status([(room, "open")])
        #expect(status.lines == [.init(name: "Fallback", state: "Unknown"), .init(name: "Name of radstelle", state: "Open")])
        #expect(status.tooltip == "Fallback: Unknown\nName of radstelle: Open")
    }

    @Test func statesAreUnknownWhileNotConnected() {
        let status = status([(space, "open")], connected: false)
        #expect(status.icon == .unknown)
        #expect(status.lines[0] == .init(name: "Name of space", state: "Unknown"))
        #expect(status.tooltip == "Not connected")
    }

    @Test func nothingFollowedShowsTheClosedDoor() {
        let status = StateBoard().trayStatus(following: [], connected: false, name: { _ in "" })
        #expect(status == TrayStatus(icon: .closed, lines: [], tooltip: "No spaces followed"))
    }

    @Test func menuHasLinesThenSettingsAndQuit() {
        let status = TrayStatus(icon: .open, lines: [.init(name: "A", state: "Open"), .init(name: "B", state: "Closed")], tooltip: "")
        let menu = TrayMenu(status, settingsAvailable: true)
        #expect(menu.items.map(\.label) == ["A — Open", "B — Closed", "", "Settings…", "", "Quit"])
        #expect(menu.items.map(\.enabled) == [false, false, true, true, true, true])
        #expect(Set(menu.items.map(\.id)).count == menu.items.count)
        #expect(menu.items[3].id == TrayMenu.settingsId)
        #expect(menu.items[5].id == TrayMenu.quitId)
    }

    @Test func menuWithoutSpacesOrSettingsProgram() {
        let menu = TrayMenu(TrayStatus(icon: .unknown, lines: [], tooltip: ""), settingsAvailable: false)
        #expect(menu.items[0] == .init(id: 100, label: "No spaces followed", enabled: false))
        #expect(menu.items.first { $0.id == TrayMenu.settingsId }?.enabled == false)
    }

    @Test func roomsStandFlatWithTheirWholeName() {
        var board = StateBoard()
        _ = board.resync(space, name: "Mainframe", state: "open")
        _ = board.resync(room, name: "Mainframe · Radstelle", state: "closed")
        let status = board.trayStatus(following: [space, room], connected: true, name: { _ in "" })
        #expect(TrayMenu(status, settingsAvailable: false).items.prefix(2).map(\.label)
            == ["Mainframe — Open", "Mainframe · Radstelle — Closed"])
    }

    @Test func underscoresInNamesStayLiteral() {
        let status = TrayStatus(icon: .open, lines: [.init(name: "c_base", state: "Open")], tooltip: "")
        #expect(TrayMenu(status, settingsAvailable: false).items[0].label == "c__base — Open")
    }
}
