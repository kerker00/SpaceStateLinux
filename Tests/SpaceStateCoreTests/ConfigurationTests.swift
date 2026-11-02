import Foundation
import SpacePushClient
import SpaceStateCore
import Testing

struct ConfigurationTests {
    @Test func theTrayListsAllRoomsRightAfterMainframe() {
        let mainframe = URL(string: "https://status.mainframe.io/api/spaceInfo")!
        let other = URL(string: "https://example.org/spaceapi.json")!
        let rooms = [RoomChoice(id: "radstelle", name: "Radstelle"), RoomChoice(id: "lab3d", name: "3D Lab")]
        let configuration = Configuration(
            spaces: [SavedSpace(endpoint: other), SavedSpace(endpoint: mainframe)],
            settings: DesktopSettings(rooms: [.init(endpoint: mainframe, room: "lab3d"), .init(endpoint: mainframe, room: "gone")]))
        #expect(configuration.followsMainframe)
        #expect(configuration.displayedTopics(rooms: rooms) == [
            PushSubscription(endpoint: other), PushSubscription(endpoint: mainframe),
            PushSubscription(endpoint: mainframe, room: "radstelle"), PushSubscription(endpoint: mainframe, room: "lab3d"),
            PushSubscription(endpoint: mainframe, room: "gone"),
        ])
        // Notifications stay with what was chosen.
        #expect(configuration.subscriptions.filter { $0.room != nil }.map(\.room) == ["lab3d", "gone"])
    }

    @Test func roomsCountOnlyWhileMainframeIsSaved() {
        let mainframe = URL(string: "https://status.mainframe.io/api/spaceInfo")!
        let other = URL(string: "https://example.org/spaceapi.json")!
        let settings = DesktopSettings(rooms: [.init(endpoint: mainframe, room: "lab3d")])
        let rooms = [RoomChoice(id: "lab3d", name: "3D Lab")]
        let without = Configuration(spaces: [SavedSpace(endpoint: other)], settings: settings)
        #expect(!without.followsMainframe)
        #expect(without.subscriptions == [PushSubscription(endpoint: other)])
        #expect(without.displayedTopics(rooms: rooms) == [PushSubscription(endpoint: other)])
        // The choice stays in the settings, so it is back with Mainframe.
        let with = Configuration(spaces: [SavedSpace(endpoint: mainframe)], settings: settings)
        #expect(with.subscriptions == [PushSubscription(endpoint: mainframe), PushSubscription(endpoint: mainframe, room: "lab3d")])
    }

    @Test func installedIconsAreFoundLikeTheIconThemeSpecificationSays() {
        let icon = "icons/hicolor/scalable/status/net.grafixmafia.SpaceState-open-symbolic.svg"
        func find(_ environment: [String: String], in roots: [String]) -> String? {
            let files = Set(roots.map { "\($0)/\(icon)" })
            return Paths.installedIcons(environment, exists: { files.contains($0) })
        }
        let status = "/icons/hicolor/scalable/status"
        #expect(find(["HOME": "/h"], in: ["/h/.local/share", "/usr/share"]) == "/h/.local/share\(status)")
        #expect(find(["HOME": "/h"], in: ["/usr/share"]) == "/usr/share\(status)")
        #expect(find(["HOME": "/h", "XDG_DATA_HOME": "/d"], in: ["/d"]) == "/d\(status)")
        #expect(find(["HOME": "/h", "XDG_DATA_DIRS": "/a:/b"], in: ["/b"]) == "/b\(status)")
        #expect(find(["HOME": "/h", "XDG_DATA_DIRS": "/a:/b"], in: ["/usr/share"]) == nil)
        #expect(find(["HOME": "/h"], in: []) == nil)
    }

    @Test func displayNamesPreferTheSavedName() {
        let named = URL(string: "https://status.mainframe.io/api/spaceInfo")!
        let unnamed = URL(string: "https://example.org/spaceapi.json")!
        let configuration = Configuration(spaces: [SavedSpace(endpoint: named, name: "Mainframe")])
        #expect(configuration.displayName(for: PushSubscription(endpoint: named)) == "Mainframe")
        #expect(configuration.displayName(for: PushSubscription(endpoint: named, room: "lab3d")) == "Mainframe · lab3d")
        #expect(configuration.displayName(for: PushSubscription(endpoint: unnamed)) == "example.org")
    }

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
