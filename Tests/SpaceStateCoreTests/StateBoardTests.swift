import Foundation
import SpacePushClient
import SpaceStateCore
import Testing

struct StateBoardTests {
    static let mainframe = URL(string: "https://status.mainframe.io/api/spaceInfo")!
    let space = PushSubscription(endpoint: mainframe)
    let room = PushSubscription(endpoint: mainframe, room: "radstelle")

    func change(_ room: String = "space", name: String = "Mainframe", from: String? = "closed", to: String? = "open",
                kind: StateChange.Kind = .change) -> StateChange {
        StateChange(kind: kind, endpoint: Self.mainframe, room: room, name: name, from: from, to: to, at: Date())
    }

    @Test func changeShowsTheNewState() {
        var board = StateBoard()
        #expect(board.apply(change()) == Alert(id: "https://status.mainframe.io/api/spaceInfo|space",
                                                summary: "Mainframe", body: "Open"))
        #expect(board.entries[space] == .init(name: "Mainframe", state: "open"))
    }

    @Test func roomsHaveTheirOwnId() {
        var board = StateBoard()
        let alert = board.apply(change("radstelle", name: "Mainframe · Radstelle", to: "keyholder"))
        #expect(alert?.id == "https://status.mainframe.io/api/spaceInfo|radstelle")
        #expect(alert?.body == "Keyholder present")
        #expect(board.entries[room]?.state == "keyholder")
    }

    @Test func knownStateIsNotShownAgain() {
        var board = StateBoard()
        #expect(board.resync(space, name: "Mainframe", state: "open") == nil)
        #expect(board.apply(change()) == nil)
        #expect(board.apply(change(from: "open", to: "closed"))?.body == "Closed")
    }

    @Test func testEventsAreAlwaysShownAndChangeNothing() {
        var board = StateBoard()
        let alert = board.apply(change(from: nil, to: nil, kind: .test))
        #expect(alert?.body == "Test notification from SpacePush. This is not a status change.")
        #expect(board.entries.isEmpty)
    }

    @Test func resyncReportsMissedChangesOnly() {
        var board = StateBoard()
        #expect(board.resync(space, name: "Mainframe", state: "closed") == nil)
        #expect(board.resync(space, name: "Mainframe", state: "closed") == nil)
        #expect(board.resync(space, name: "Other name", state: "open")
            == Alert(id: Alert.id(for: space), summary: "Mainframe", body: "Open"))
    }

    @Test func unknownStatesAreShownAsSent() {
        #expect(AlertTexts().describe("party") == "party")
        #expect(AlertTexts(translate: { "[\($0)]" }).describe("open_plus") == "[Open+]")
    }

    @Test func forgetsUnfollowedTopics() {
        var board = StateBoard()
        _ = board.resync(space, name: "Mainframe", state: "open")
        _ = board.resync(room, name: "Mainframe · Radstelle", state: "closed")
        board.keep(only: [room])
        #expect(Array(board.entries.keys) == [room])
    }
}
