import Foundation
import SpacePushClient
import SpaceStateCore
import Testing

struct ConfigurationTests {
    let mainframe = URL(string: "https://status.mainframe.io/api/spaceInfo")!

    @Test func parsesTheCLIFormat() {
        let parsed = SavedSpacesFile.parse("""
            # Spaces shown by `spacestate` without arguments: endpoint, then an optional # name.
            https://status.mainframe.io/api/spaceInfo  # Mainframe\r
            https://example.org/spaceapi.json

            """)
        #expect(parsed.spaces == [
            SavedSpace(endpoint: mainframe, name: "Mainframe"),
            SavedSpace(endpoint: URL(string: "https://example.org/spaceapi.json")!),
        ])
        #expect(parsed.problems.isEmpty)
    }

    @Test func skipsLinesItCannotUse() {
        let parsed = SavedSpacesFile.parse("not a url\nhttps://example.org/a.json trailing words\nhttps://example.org/b.json")
        #expect(parsed.spaces.map(\.endpoint.absoluteString) == ["https://example.org/b.json"])
        #expect(parsed.problems.count == 2)
        #expect(parsed.problems.first?.hasPrefix("spaces, line 1:") == true)
    }

    @Test func settingsTakeDefaultsForMissingKeys() throws {
        let settings = try JSONDecoder().decode(DesktopSettings.self, from: Data(#"{"future": true}"#.utf8))
        #expect(settings == DesktopSettings())
        #expect(Configuration(settings: settings).pushServer == DesktopSettings.defaultPushServer)
    }

    @Test func subscriptionsCombineSpacesAndRooms() {
        let configuration = Configuration(
            spaces: [SavedSpace(endpoint: mainframe), SavedSpace(endpoint: mainframe)],
            settings: DesktopSettings(rooms: [.init(endpoint: mainframe, room: "radstelle")]))
        #expect(configuration.subscriptions == [
            PushSubscription(endpoint: mainframe),
            PushSubscription(endpoint: mainframe, room: "radstelle"),
        ])
    }

    @Test func loadsFilesAndReportsProblems() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "spacestate-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let spaces = directory.appending(path: "spaces")
        let settings = directory.appending(path: "desktop.json")

        #expect(Configuration.load(spacesFile: spaces, settingsFile: settings) == Configuration())

        try "https://status.mainframe.io/api/spaceInfo\n".write(to: spaces, atomically: true, encoding: .utf8)
        try "{broken".write(to: settings, atomically: true, encoding: .utf8)
        let loaded = Configuration.load(spacesFile: spaces, settingsFile: settings)
        #expect(loaded.spaces == [SavedSpace(endpoint: mainframe)])
        #expect(loaded.settings == DesktopSettings())
        #expect(loaded.problems.count == 1)
    }

    @Test func pathsFollowXDG() {
        #expect(Paths.savedSpaces(["XDG_CONFIG_HOME": "/cfg", "HOME": "/home/u"]).path == "/cfg/spacestate/spaces")
        #expect(Paths.desktopSettings(["XDG_CONFIG_HOME": "relative", "HOME": "/home/u"]).path
            == "/home/u/.config/spacestate/desktop.json")
    }
}
