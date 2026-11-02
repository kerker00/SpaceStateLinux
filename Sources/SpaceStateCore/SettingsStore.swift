import Foundation
import MainframeStatus
import SpaceAPI
import SpacePushClient

extension SavedSpacesFile {
    static let header = "# Spaces shown by `spacestate` without arguments: endpoint, then an optional # name."

    /// The file's content with the space appended, as SpaceStateCLI writes it. Other lines stay as they are.
    public static func adding(_ space: SavedSpace, to content: String) -> String {
        guard !parse(content).spaces.contains(where: { $0.endpoint == space.endpoint }) else { return content }
        var lines = lines(of: content)
        if lines.isEmpty { lines = [header] }
        // The name is a comment on one line, so control characters cannot stay in it.
        let name = space.name.map { name in
            String(String.UnicodeScalarView(name.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
        }
        lines.append(name.map { "\(space.endpoint.absoluteString)  # \($0)" } ?? space.endpoint.absoluteString)
        return lines.joined(separator: "\n") + "\n"
    }

    /// The file's content without the lines of this endpoint. Other lines stay as they are.
    public static func removing(_ endpoint: URL, from content: String) -> String {
        let kept = lines(of: content).filter { parse($0).spaces.first?.endpoint != endpoint }
        return kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
    }

    private static func lines(of content: String) -> [String] {
        // CRLF is one Character in Swift, so normalize it before splitting by LF.
        var lines = content.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }
}

/// Writes what the settings window changes. Every change starts from the file as it is now,
/// so it keeps what `spacestate add` or a text editor wrote in the meantime.
public struct SettingsStore: Sendable {
    public enum Problem: Error, Equatable {
        /// `desktop.json` cannot be read, and writing would lose what is in it.
        case unreadableSettings(String)
        case invalidServer(String)
    }

    public let spacesFile: URL
    public let settingsFile: URL
    public let autostartFile: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        spacesFile = Paths.savedSpaces(environment)
        settingsFile = Paths.desktopSettings(environment)
        autostartFile = Paths.autostartEntry(environment)
    }

    // MARK: Spaces

    public func spaces() throws -> [SavedSpace] {
        SavedSpacesFile.parse(try spacesContent()).spaces
    }

    public func add(_ space: SavedSpace) throws {
        try write(SavedSpacesFile.adding(space, to: try spacesContent()), to: spacesFile)
    }

    public func remove(_ endpoint: URL) throws {
        try write(SavedSpacesFile.removing(endpoint, from: try spacesContent()), to: spacesFile)
    }

    private func spacesContent() throws -> String {
        guard FileManager.default.fileExists(atPath: spacesFile.path) else { return "" }
        return try String(contentsOf: spacesFile, encoding: .utf8)
    }

    // MARK: Settings

    public func settings() throws -> DesktopSettings {
        guard FileManager.default.fileExists(atPath: settingsFile.path) else { return DesktopSettings() }
        do {
            return try JSONDecoder().decode(DesktopSettings.self, from: Data(contentsOf: settingsFile))
        } catch {
            throw Problem.unreadableSettings(settingsFile.path)
        }
    }

    public func setRoom(_ room: DesktopSettings.Room, followed: Bool) throws {
        var settings = try settings()
        settings.rooms.removeAll { $0 == room }
        if followed { settings.rooms.append(room) }
        try save(settings)
    }

    /// Sets the servers; an empty text means the default. The default push server is not
    /// written down, so a later release can move it.
    public func setServers(push: String, stream: String) throws {
        var settings = try settings()
        let pushServer = try Self.server(push)
        settings.pushServer = pushServer == DesktopSettings.defaultPushServer ? nil : pushServer
        settings.streamServer = try Self.server(stream)
        try save(settings)
    }

    static func server(_ text: String) throws -> URL? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        guard let url = URL(string: text), (try? SpaceEndpoint.validate(url)) != nil else {
            throw Problem.invalidServer(text)
        }
        return url
    }

    private func save(_ settings: DesktopSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try write(String(decoding: try encoder.encode(settings), as: UTF8.self) + "\n", to: settingsFile)
    }

    // MARK: Autostart

    static let autostartEntry = """
        [Desktop Entry]
        Type=Application
        Name=SpaceState
        Comment=Notifications when hackerspaces open or close
        Exec=spacestate-desktop
        Icon=net.grafixmafia.SpaceState
        Terminal=false
        NoDisplay=true
        X-GNOME-Autostart-enabled=true

        """

    /// Whether the XDG autostart entry starts the service. A systemd user unit is not seen here.
    public var autostart: Bool {
        guard let entry = try? String(contentsOf: autostartFile, encoding: .utf8) else { return false }
        return !entry.split(whereSeparator: \.isNewline).contains("Hidden=true")
    }

    public func setAutostart(_ enabled: Bool) throws {
        if enabled {
            try write(Self.autostartEntry, to: autostartFile)
        } else if FileManager.default.fileExists(atPath: autostartFile.path) {
            try FileManager.default.removeItem(at: autostartFile)
        }
    }

    private func write(_ content: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: file, options: .atomic)
    }
}

/// A space from the SpacePush directory that the settings window offers.
public struct SpaceChoice: Sendable, Equatable {
    public var name: String
    public var endpoint: URL
    /// Where it is, as far as the space says, such as a postal address.
    public var place: String?

    public init(name: String, endpoint: URL, place: String? = nil) {
        self.name = name
        self.endpoint = endpoint
        self.place = place
    }

    /// With an empty query all of them, as given. Otherwise those whose name or place contains
    /// it: names starting with it first, then other names, then places.
    public static func search(_ query: String, in choices: [SpaceChoice]) -> [SpaceChoice] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return choices }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func rank(_ choice: SpaceChoice) -> Int? {
            if choice.name.range(of: query, options: options.union(.anchored)) != nil { return 0 }
            if choice.name.range(of: query, options: options) != nil { return 1 }
            if choice.place?.range(of: query, options: options) != nil { return 2 }
            return nil
        }
        return choices.compactMap { choice in rank(choice).map { (choice, $0) } }
            .enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map(\.element.0)
    }

    /// One row of the window's list.
    public struct Row: Sendable, Equatable {
        public var choice: SpaceChoice
        public var followed: Bool

        public init(choice: SpaceChoice, followed: Bool) {
            self.choice = choice
            self.followed = followed
        }
    }

    /// What the list shows: followed spaces first, including those the directory does not know.
    public static func rows(_ query: String, directory: [SpaceChoice], followed: [SavedSpace]) -> [Row] {
        let known = Dictionary(directory.map { ($0.endpoint, $0) }, uniquingKeysWith: { first, _ in first })
        let endpoints = Set(followed.map(\.endpoint))
        let mine = followed.map { space in
            known[space.endpoint] ?? SpaceChoice(name: space.name ?? space.endpoint.host() ?? space.endpoint.absoluteString,
                                                 endpoint: space.endpoint)
        }
        return search(query, in: mine).map { Row(choice: $0, followed: true) }
            + search(query, in: directory.filter { !endpoints.contains($0.endpoint) }).map { Row(choice: $0, followed: false) }
    }

    /// The spaces SpacePush can follow: only those in its directory.
    public static func load(pushServer: URL, userAgent: String) async throws -> [SpaceChoice] {
        let client = SpacePushClient(baseURL: pushServer, headers: ["User-Agent": userAgent])
        return try await client.directory().map {
            SpaceChoice(name: $0.info.name, endpoint: $0.endpoint, place: $0.info.location?.address)
        }
    }
}

/// A Mainframe room that the settings window offers.
public struct RoomChoice: Sendable, Equatable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public var room: DesktopSettings.Room {
        DesktopSettings.Room(endpoint: Mainframe.spaceAPIEndpoint, room: id)
    }

    /// Rooms are a choice once Mainframe is followed, and stay one while any is
    /// followed, so they can still be removed.
    public static func areOffered(spaces: [SavedSpace], rooms: [DesktopSettings.Room]) -> Bool {
        !rooms.isEmpty || spaces.contains { Mainframe.isMainframe($0.endpoint) }
    }

    /// The rooms besides `space`, which is followed as the space itself.
    public static func choices(_ rooms: [MainframeRoom]) -> [RoomChoice] {
        rooms.filter { $0.id != "space" }.map { RoomChoice(id: $0.id, name: $0.name) }
    }

    public static func load(pushServer: URL, userAgent: String) async throws -> [RoomChoice] {
        let client = SpacePushClient(baseURL: pushServer, headers: ["User-Agent": userAgent])
        return choices(try await StatusService(spacePush: client).mainframeRooms())
    }
}
