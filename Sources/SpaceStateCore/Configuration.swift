import Foundation
import SpaceAPI
import SpacePushClient

/// Where the configuration lives, following the XDG base directories like SpaceStateCLI.
public enum Paths {
    public static func configDirectory(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["XDG_CONFIG_HOME"], path.hasPrefix("/") {
            return URL(filePath: path).appending(path: "spacestate")
        }
        let home = environment["HOME"].map { URL(filePath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appending(path: ".config/spacestate")
    }

    /// The saved spaces, shared with SpaceStateCLI.
    public static func savedSpaces(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        configDirectory(environment).appending(path: "spaces")
    }

    /// Rooms and settings of the desktop app.
    public static func desktopSettings(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        configDirectory(environment).appending(path: "desktop.json")
    }

    /// The XDG autostart entry that starts the service with the session.
    public static func autostartEntry(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        configDirectory(environment).deletingLastPathComponent()
            .appending(path: "autostart/net.grafixmafia.SpaceState.desktop")
    }
}

/// A space from the `spaces` file.
public struct SavedSpace: Sendable, Equatable {
    public var endpoint: URL
    public var name: String?

    public init(endpoint: URL, name: String? = nil) {
        self.endpoint = endpoint
        self.name = name
    }
}

/// Reads SpaceStateCLI's `spaces` file: one endpoint per line and an optional `# name`.
/// Shared with the CLI: reading skips lines it cannot use, and writing keeps them.
public enum SavedSpacesFile {
    public static func parse(_ content: String) -> (spaces: [SavedSpace], problems: [String]) {
        var spaces: [SavedSpace] = []
        var problems: [String] = []
        // CRLF is one Character in Swift, so normalize it before splitting by LF.
        let lines = content.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let url = trimmed.prefix { !$0.isWhitespace }
            let rest = trimmed.dropFirst(url.count).trimmingCharacters(in: .whitespaces)
            guard rest.isEmpty || rest.hasPrefix("#"), let endpoint = try? SpaceEndpoint.parse(String(url)) else {
                problems.append("spaces, line \(index + 1): expected one endpoint followed by an optional # comment")
                continue
            }
            let name = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            spaces.append(SavedSpace(endpoint: endpoint, name: name.isEmpty ? nil : name))
        }
        return (spaces, problems)
    }
}

/// The desktop app's own settings in `desktop.json`. Missing keys take their defaults.
public struct DesktopSettings: Sendable, Equatable, Codable {
    /// A Mainframe room to follow in addition to the saved spaces.
    public struct Room: Sendable, Equatable, Codable {
        public var endpoint: URL
        public var room: String

        public init(endpoint: URL, room: String) {
            self.endpoint = endpoint
            self.room = room
        }
    }

    public var rooms: [Room]
    /// The SpacePush server; nil uses `DesktopSettings.defaultPushServer`.
    public var pushServer: URL?
    /// Where the server serves `/v1/stream`, if not at the push server.
    public var streamServer: URL?

    public static let defaultPushServer = URL(string: "https://push.grafixmafia.net")!

    public init(rooms: [Room] = [], pushServer: URL? = nil, streamServer: URL? = nil) {
        self.rooms = rooms
        self.pushServer = pushServer
        self.streamServer = streamServer
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rooms = try container.decodeIfPresent([Room].self, forKey: .rooms) ?? []
        pushServer = try container.decodeIfPresent(URL.self, forKey: .pushServer)
        streamServer = try container.decodeIfPresent(URL.self, forKey: .streamServer)
    }
}

/// Everything the service follows, read from both files.
public struct Configuration: Sendable, Equatable {
    public var spaces: [SavedSpace]
    public var settings: DesktopSettings
    /// Lines or files that could not be used; the rest of the configuration still applies.
    public var problems: [String]

    public init(spaces: [SavedSpace] = [], settings: DesktopSettings = DesktopSettings(), problems: [String] = []) {
        self.spaces = spaces
        self.settings = settings
        self.problems = problems
    }

    /// Reads both files. Missing files are an empty configuration, not an error.
    public static func load(spacesFile: URL = Paths.savedSpaces(), settingsFile: URL = Paths.desktopSettings()) -> Configuration {
        var configuration = Configuration()
        if let content = read(spacesFile, into: &configuration.problems) {
            let parsed = SavedSpacesFile.parse(content)
            configuration.spaces = parsed.spaces
            configuration.problems += parsed.problems
        }
        if let content = read(settingsFile, into: &configuration.problems) {
            do {
                configuration.settings = try JSONDecoder().decode(DesktopSettings.self, from: Data(content.utf8))
            } catch {
                configuration.problems.append("\(settingsFile.lastPathComponent): \(error)")
            }
        }
        return configuration
    }

    private static func read(_ file: URL, into problems: inout [String]) -> String? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            return try String(contentsOf: file, encoding: .utf8)
        } catch {
            problems.append("\(file.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    /// The stream subscriptions: each saved space, then each room, without duplicates.
    public var subscriptions: [PushSubscription] {
        var seen = Set<PushSubscription>()
        let all = spaces.map { PushSubscription(endpoint: $0.endpoint) }
            + settings.rooms.map { PushSubscription(endpoint: $0.endpoint, room: $0.room) }
        return all.filter { seen.insert($0).inserted }
    }

    public var pushServer: URL { settings.pushServer ?? DesktopSettings.defaultPushServer }

    /// A name for a topic whose state has not been read yet.
    @Sendable public func displayName(for topic: PushSubscription) -> String {
        let space = spaces.first { $0.endpoint == topic.endpoint }?.name
            ?? topic.endpoint.host() ?? topic.endpoint.absoluteString
        return topic.room.map { "\(space) · \($0)" } ?? space
    }
}
