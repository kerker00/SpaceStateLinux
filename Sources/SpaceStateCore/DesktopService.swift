import Foundation
import SpacePushClient

/// Follows SpacePush's change stream for the configured spaces and rooms and
/// hands the notifications to show to `show`. After each connection it reads the
/// current states, because changes are not replayed while disconnected.
public struct DesktopService: Sendable {
    public typealias Events = @Sendable () -> AsyncThrowingStream<ChangeFeedEvent, any Error>

    public let subscriptions: [PushSubscription]
    let events: Events
    let read: StateReader.Read
    let texts: AlertTexts
    let show: @Sendable (Alert) async -> Void
    let log: @Sendable (String) -> Void
    let name: @Sendable (PushSubscription) -> String
    let status: @Sendable (TrayStatus) async -> Void

    public init(subscriptions: [PushSubscription], events: @escaping Events, read: @escaping StateReader.Read,
                texts: AlertTexts = AlertTexts(), show: @escaping @Sendable (Alert) async -> Void,
                status: @escaping @Sendable (TrayStatus) async -> Void = { _ in },
                name: @escaping @Sendable (PushSubscription) -> String = { $0.endpoint.host() ?? $0.endpoint.absoluteString },
                log: @escaping @Sendable (String) -> Void) {
        self.subscriptions = subscriptions
        self.events = events
        self.read = read
        self.texts = texts
        self.show = show
        self.status = status
        self.name = name
        self.log = log
    }

    /// The service for a configuration, talking to its SpacePush server.
    public init(configuration: Configuration, userAgent: String, texts: AlertTexts = AlertTexts(),
                show: @escaping @Sendable (Alert) async -> Void,
                status: @escaping @Sendable (TrayStatus) async -> Void = { _ in },
                log: @escaping @Sendable (String) -> Void) {
        let client = SpacePushClient(baseURL: configuration.pushServer, headers: ["User-Agent": userAgent])
        let feed = ChangeFeed(client: client, subscriptions: configuration.subscriptions,
                              streamBaseURL: configuration.settings.streamServer)
        self.init(subscriptions: configuration.subscriptions, events: { feed.events() },
                  read: StateReader.live(StatusService(spacePush: client), log: log),
                  texts: texts, show: show, status: status, name: configuration.displayName, log: log)
    }

    /// Runs until cancelled, or until the server refuses the subscriptions.
    public func run() async {
        var board = StateBoard(texts: texts)
        func publish(connected: Bool) async {
            await status(board.trayStatus(following: subscriptions, connected: connected, name: name))
        }
        await publish(connected: false)
        guard !subscriptions.isEmpty else {
            log("No spaces to follow. Add some with `spacestate add` or in the settings.")
            return
        }
        do {
            for try await event in events() {
                switch event {
                case .connected:
                    log("Connected; following \(subscriptions.count) topic\(subscriptions.count == 1 ? "" : "s").")
                    board.keep(only: subscriptions)
                    for reading in await read(subscriptions) {
                        if let alert = board.resync(reading.topic, name: reading.name, state: reading.state) {
                            await show(alert)
                        }
                    }
                    await publish(connected: true)
                case .change(let change):
                    if let alert = board.apply(change) { await show(alert) }
                    await publish(connected: true)
                case .disconnected(let reason, let retryIn):
                    log("Change stream: \(reason); reconnecting in \(retryIn.components.seconds) s.")
                    await publish(connected: false)
                }
            }
        } catch is CancellationError {
        } catch SpacePushError.httpStatus(let status, let reason) {
            log("Change stream refused (\(status) \(reason ?? "")): SpacePush follows only spaces in its directory.")
        } catch {
            log("Change stream unavailable: \(error)")
        }
        // A stream that ended for good leaves nothing connected; a cancelled run has a successor.
        if !Task.isCancelled { await publish(connected: false) }
    }
}
