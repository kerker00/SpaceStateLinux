import Foundation
import MainframeStatus
import SpaceStateCore
import Testing

struct SettingsStoreTests {
    static let mainframe = URL(string: "https://status.mainframe.io/api/spaceInfo")!
    static let other = URL(string: "https://example.org/spaceapi.json")!
    let room = DesktopSettings.Room(endpoint: mainframe, room: "radstelle")

    /// A store in a new temporary config directory.
    func store() throws -> SettingsStore {
        let home = FileManager.default.temporaryDirectory.appending(path: "spacestate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return SettingsStore(environment: ["HOME": home.path, "XDG_CONFIG_HOME": home.path])
    }

    func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    // MARK: The shared spaces file

    @Test func addingToAnEmptyFileWritesTheCLIFormat() {
        let content = SavedSpacesFile.adding(SavedSpace(endpoint: Self.mainframe, name: "Mainframe"), to: "")
        #expect(content == """
            # Spaces shown by `spacestate` without arguments: endpoint, then an optional # name.
            https://status.mainframe.io/api/spaceInfo  # Mainframe

            """)
        #expect(SavedSpacesFile.parse(content).spaces == [SavedSpace(endpoint: Self.mainframe, name: "Mainframe")])
    }

    @Test func addingKeepsOtherLinesAndSkipsKnownSpaces() {
        let content = "# my list\n\nnot a url at all\n\(Self.other)\n"
        let added = SavedSpacesFile.adding(SavedSpace(endpoint: Self.mainframe), to: content)
        #expect(added == content + "\(Self.mainframe)\n")
        #expect(SavedSpacesFile.adding(SavedSpace(endpoint: Self.other, name: "New name"), to: content) == content)
    }

    @Test func namesStayOnOneLine() {
        let content = SavedSpacesFile.adding(SavedSpace(endpoint: Self.mainframe, name: "Evil\nhttps://example.org/x"), to: "")
        #expect(SavedSpacesFile.parse(content).spaces.map(\.endpoint) == [Self.mainframe])
    }

    @Test func removingKeepsOtherLines() {
        let content = "# my list\r\n\(Self.mainframe)  # Mainframe\r\n\(Self.other)\r\nbroken line here\r\n"
        #expect(SavedSpacesFile.removing(Self.mainframe, from: content) == "# my list\n\(Self.other)\nbroken line here\n")
        #expect(SavedSpacesFile.removing(Self.mainframe, from: "\(Self.mainframe)\n") == "")
    }

    @Test func storeChangesStartFromTheFileAsItIsNow() throws {
        let store = try store()
        try store.add(SavedSpace(endpoint: Self.mainframe, name: "Mainframe"))
        // Another program, such as `spacestate add`, writes in between.
        let content = try String(contentsOf: store.spacesFile, encoding: .utf8)
        try write(content + "\(Self.other)  # Other\n", to: store.spacesFile)
        try store.remove(Self.mainframe)
        #expect(try store.spaces() == [SavedSpace(endpoint: Self.other, name: "Other")])
    }

    // MARK: desktop.json

    @Test func roomsAreAddedOnceAndRemoved() throws {
        let store = try store()
        try store.setRoom(room, followed: true)
        try store.setRoom(room, followed: true)
        #expect(try store.settings().rooms == [room])
        try store.setRoom(room, followed: false)
        #expect(try store.settings().rooms.isEmpty)
    }

    @Test func serversAreSetValidatedAndCleared() throws {
        let store = try store()
        try store.setRoom(room, followed: true)
        try store.setServers(push: " https://push.example.org ", stream: "")
        #expect(try store.settings().pushServer == URL(string: "https://push.example.org"))
        #expect(try store.settings().streamServer == nil)
        #expect(try store.settings().rooms == [room])
        #expect(throws: SettingsStore.Problem.invalidServer("not a url")) {
            try store.setServers(push: "not a url", stream: "")
        }
        #expect(try store.settings().pushServer == URL(string: "https://push.example.org"))
        try store.setServers(push: "", stream: "")
        #expect(try store.settings().pushServer == nil)
    }

    @Test func theDefaultPushServerIsNotWrittenDown() throws {
        let store = try store()
        try store.setServers(push: DesktopSettings.defaultPushServer.absoluteString, stream: "")
        #expect(try store.settings().pushServer == nil)
    }

    @Test func aBrokenSettingsFileIsNotOverwritten() throws {
        let store = try store()
        try write("{ my unfinished edit", to: store.settingsFile)
        #expect(throws: SettingsStore.Problem.unreadableSettings(store.settingsFile.path)) {
            try store.setRoom(room, followed: true)
        }
        #expect(try String(contentsOf: store.settingsFile, encoding: .utf8) == "{ my unfinished edit")
    }

    @Test func theServiceReadsWhatTheStoreWrites() throws {
        let store = try store()
        try store.add(SavedSpace(endpoint: Self.mainframe, name: "Mainframe"))
        try store.setRoom(room, followed: true)
        let configuration = Configuration.load(spacesFile: store.spacesFile, settingsFile: store.settingsFile)
        #expect(configuration.problems.isEmpty)
        #expect(configuration.subscriptions.count == 2)
    }

    // MARK: Autostart

    @Test func autostartWritesAndRemovesTheEntry() throws {
        let store = try store()
        #expect(!store.autostart)
        try store.setAutostart(true)
        #expect(store.autostart)
        let entry = try String(contentsOf: store.autostartFile, encoding: .utf8)
        #expect(entry.hasPrefix("[Desktop Entry]\n"))
        #expect(entry.contains("\nExec=spacestate-desktop\n"))
        #expect(store.autostartFile.path.hasSuffix("/autostart/net.grafixmafia.SpaceState.desktop"))
        try store.setAutostart(false)
        #expect(!store.autostart)
        try store.setAutostart(false)
    }

    @Test func aHiddenEntryIsOff() throws {
        let store = try store()
        try write("[Desktop Entry]\nHidden=true\n", to: store.autostartFile)
        #expect(!store.autostart)
    }

    // MARK: Choices

    func choice(_ name: String, place: String? = nil) -> SpaceChoice {
        SpaceChoice(name: name, endpoint: URL(string: "https://example.org/\(name.count)-\(name.hashValue)")!, place: place)
    }

    @Test func searchRanksNamesBeforePlaces() {
        let choices = [choice("Chaos Mainframe"), choice("In Oldenburg", place: "Berlin"), choice("Mainframe", place: "Bahnhofsplatz 10, Oldenburg"),
                       choice("Köln"), choice("Other", place: "Via Rustici 4, L'Aquila, Italy")]
        #expect(SpaceChoice.search("main", in: choices).map(\.name) == ["Mainframe", "Chaos Mainframe"])
        #expect(SpaceChoice.search(" KOLN ", in: choices).map(\.name) == ["Köln"])
        #expect(SpaceChoice.search("oldenburg", in: choices).map(\.name) == ["In Oldenburg", "Mainframe"])
        #expect(SpaceChoice.search("italy", in: choices).map(\.name) == ["Other"])
        #expect(SpaceChoice.search("nowhere", in: choices).isEmpty)
    }

    @Test func namesSortAsPeopleReadThem() {
        let names = ["NYCResistor", "Évry", "Nerd2Nerd", "c-base", "Zeta", "Nerd10", "Eins"]
        #expect(SpaceChoice.sorted(names.map { choice($0) }).map(\.name)
            == ["c-base", "Eins", "Évry", "Nerd2Nerd", "Nerd10", "NYCResistor", "Zeta"])
    }

    @Test func anEmptySearchListsEverythingInOrder() {
        let choices = [choice("B"), choice("A")]
        #expect(SpaceChoice.search("  ", in: choices) == choices)
    }

    @Test func rowsPutFollowedSpacesFirst() {
        let a = choice("A"), b = choice("B"), c = choice("C", place: "Oldenburg")
        let unknown = URL(string: "https://unknown.example.org/api")!
        let followed = [SavedSpace(endpoint: c.endpoint, name: "Saved name"), SavedSpace(endpoint: unknown, name: "From the CLI")]
        let rows = SpaceChoice.rows("", directory: [a, b, c], followed: followed)
        #expect(rows.map(\.choice.name) == ["C", "From the CLI", "A", "B"])
        #expect(rows.map(\.followed) == [true, true, false, false])
        #expect(SpaceChoice.rows("oldenburg", directory: [a, b, c], followed: followed).map(\.choice.name) == ["C"])
        #expect(SpaceChoice.rows("", directory: [], followed: []).isEmpty)
    }

    @Test func roomsAreOfferedOnlyWithMainframe() {
        #expect(!RoomChoice.areOffered(spaces: [SavedSpace(endpoint: Self.other)]))
        #expect(RoomChoice.areOffered(spaces: [SavedSpace(endpoint: Self.other), SavedSpace(endpoint: Self.mainframe)]))
    }

    @Test func roomChoicesLeaveOutTheSpaceItself() {
        let rooms = [MainframeRoom(id: "space", state: .closed, since: nil), MainframeRoom(id: "lab3d", state: .closed, since: nil)]
        #expect(RoomChoice.choices(rooms) == [RoomChoice(id: "lab3d", name: "3D Lab")])
        #expect(RoomChoice(id: "radstelle", name: "Radstelle").room == room)
    }
}
