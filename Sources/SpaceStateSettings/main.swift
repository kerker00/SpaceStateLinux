import CGtk
import Foundation
import SpaceStateCore

// spacestate-settings: the window that manages what spacestate-desktop follows. It only writes
// the configuration files; the service notices the change and reloads. All logic is in Core.

let version = "0.1.0-dev"

/// Lives for the whole process. All fields are used on the GLib main loop only.
final class SettingsApp: @unchecked Sendable {
    let app: UnsafeMutablePointer<GtkApplication>
    let store = SettingsStore()
    var userAgent: String { "spacestate-settings/\(version)" }
    var window: Widget?
    var search: Widget!
    var spacesList: Widget!
    var roomsList: Widget!
    var autostart: Widget!
    var pushServer: Widget!
    var streamServer: Widget!
    var statusLabel: Widget!
    /// Nil until loaded, and again after a failure, so the next search tries again.
    var directory: [SpaceChoice]?
    var loadingDirectory = false
    var rooms: [RoomChoice] = []

    init() {
        app = gtk_application_new("net.grafixmafia.SpaceState.Settings", GApplicationFlags(rawValue: 0))
    }

    var gApplication: UnsafeMutablePointer<GApplication> {
        UnsafeMutableRawPointer(app).assumingMemoryBound(to: GApplication.self)
    }

    func run() -> Int32 {
        on(app, "activate") { [unowned self] in self.present() }
        return g_application_run(gApplication, CommandLine.argc, CommandLine.unsafeArgv)
    }

    /// A launch while the window is open only brings it to the front.
    func present() {
        if window == nil { build() }
        gtk_window_present(asWindow(window!))
    }

    func asWindow(_ widget: Widget) -> UnsafeMutablePointer<GtkWindow> {
        UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkWindow.self)
    }

    func build() {
        let builder = gtk_builder_new()!
        defer { g_object_unref(UnsafeMutableRawPointer(builder)) }
        gtk_builder_set_translation_domain(builder, textDomain)
        let description = String(decoding: PackageResources.settings_ui, as: UTF8.self)
        guard gtk_builder_add_from_string(builder, description, -1, nil) != 0 else {
            fatalError("settings.ui does not load")
        }
        func widget(_ name: String) -> Widget {
            UnsafeMutableRawPointer(gtk_builder_get_object(builder, name)!).assumingMemoryBound(to: GtkWidget.self)
        }
        let window = widget("window")
        gtk_window_set_application(asWindow(window), app)
        self.window = window
        search = widget("search")
        spacesList = widget("spaces")
        roomsList = widget("rooms")
        autostart = widget("autostart")
        pushServer = widget("push_server")
        streamServer = widget("stream_server")
        statusLabel = widget("status")

        on(search, "search-changed") { [unowned self] in
            self.loadDirectoryIfNeeded()
            self.renderSpaces()
        }
        gtk_switch_set_active(OpaquePointer(autostart), store.autostart ? 1 : 0)
        onNotify(autostart, "active") { [unowned self] in self.autostartChanged() }
        on(widget("apply_servers"), "clicked") { [unowned self] in self.applyServers() }

        loadServers()
        renderSpaces()
        renderRooms()
        loadDirectoryIfNeeded()
        loadRooms()
    }

    func show(_ message: String) {
        gtk_label_set_text(OpaquePointer(statusLabel), message)
    }

    func show(_ error: any Error) {
        switch error {
        case SettingsStore.Problem.unreadableSettings(let path):
            show(String(format: translate("%@ cannot be read. Fix or remove it to change these settings."), path))
        case SettingsStore.Problem.invalidServer(let text):
            show(String(format: translate("“%@” is not a valid server address."), text))
        default:
            show(error.localizedDescription)
        }
    }

    var currentPushServer: URL {
        (try? store.settings())?.pushServer ?? DesktopSettings.defaultPushServer
    }

    // MARK: Spaces

    func loadDirectoryIfNeeded() {
        guard directory == nil, !loadingDirectory else { return }
        loadingDirectory = true
        let server = currentPushServer
        let userAgent = userAgent
        Task {
            let result = await Result { try await SpaceChoice.load(pushServer: server, userAgent: userAgent) }
            onMainLoop { [unowned self] in
                self.loadingDirectory = false
                switch result {
                case .success(let choices):
                    self.directory = choices
                    self.renderSpaces()
                case .failure:
                    self.show(translate("Could not load the directory. Search again to retry."))
                }
            }
        }
    }

    func renderSpaces() {
        let list = OpaquePointer(spacesList)
        gtk_list_box_remove_all(list)
        let followed: [SavedSpace]
        do {
            followed = try store.spaces()
        } catch {
            show(error)
            return
        }
        let query = text(of: search)
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            for space in followed {
                gtk_list_box_append(list, spaceRow(space.name ?? space.endpoint.host() ?? space.endpoint.absoluteString,
                                                   endpoint: space.endpoint, followed: true))
            }
            if followed.isEmpty { gtk_list_box_append(list, row(translate("No spaces followed yet. Search above to add one."))) }
            return
        }
        guard let directory else {
            gtk_list_box_append(list, row(translate("Loading the directory…")))
            return
        }
        let endpoints = Set(followed.map(\.endpoint))
        let matches = SpaceChoice.search(query, in: directory)
        for choice in matches {
            gtk_list_box_append(list, spaceRow(choice.name, endpoint: choice.endpoint, followed: endpoints.contains(choice.endpoint)))
        }
        if matches.isEmpty { gtk_list_box_append(list, row(translate("No space with this name in the directory."))) }
    }

    func spaceRow(_ name: String, endpoint: URL, followed: Bool) -> Widget {
        let button = gtk_button_new_with_label(followed ? translate("Remove") : translate("Add"))!
        on(button, "clicked") { [unowned self] in
            do {
                if followed {
                    try self.store.remove(endpoint)
                } else {
                    try self.store.add(SavedSpace(endpoint: endpoint, name: name))
                }
                self.show("")
            } catch {
                self.show(error)
            }
            self.renderSpaces()
        }
        return row(name, control: button)
    }

    // MARK: Rooms

    func loadRooms() {
        let server = currentPushServer
        let userAgent = userAgent
        Task {
            let result = await Result { try await RoomChoice.load(pushServer: server, userAgent: userAgent) }
            onMainLoop { [unowned self] in
                switch result {
                case .success(let rooms):
                    self.rooms = rooms
                    self.renderRooms()
                case .failure:
                    self.show(translate("Could not load the Mainframe rooms."))
                }
            }
        }
    }

    /// The server's rooms, and any followed room it does not list, so that one can still be removed.
    func renderRooms() {
        let list = OpaquePointer(roomsList)
        gtk_list_box_remove_all(list)
        let followed: [DesktopSettings.Room]
        do {
            followed = try store.settings().rooms
        } catch {
            show(error)
            return
        }
        let extra = followed.filter { room in !rooms.contains { $0.room == room } }
        let rows = rooms.map { (title: $0.name, room: $0.room) } + extra.map { (title: $0.room, room: $0) }
        for item in rows {
            let check = gtk_check_button_new_with_label(item.title)!
            gtk_widget_set_margin_top(check, 6)
            gtk_widget_set_margin_bottom(check, 6)
            let button = UnsafeMutableRawPointer(check).assumingMemoryBound(to: GtkCheckButton.self)
            gtk_check_button_set_active(button, followed.contains(item.room) ? 1 : 0)
            on(check, "toggled") { [unowned self] in
                do {
                    try self.store.setRoom(item.room, followed: gtk_check_button_get_active(button) != 0)
                    self.show("")
                } catch {
                    self.show(error)
                }
            }
            gtk_list_box_append(list, check)
        }
        if rows.isEmpty { gtk_list_box_append(list, row(translate("Loading the rooms…"))) }
    }

    // MARK: General

    func autostartChanged() {
        let enabled = gtk_switch_get_active(OpaquePointer(autostart)) != 0
        do {
            try store.setAutostart(enabled)
            show(enabled && !isInstalled("spacestate-desktop")
                ? translate("spacestate-desktop is not on your PATH, so autostart cannot start it.") : "")
        } catch {
            show(error)
        }
    }

    func loadServers() {
        guard let settings = try? store.settings() else { return }
        let set: (Widget, URL?) -> Void = { entry, url in
            gtk_editable_set_text(OpaquePointer(entry), url?.absoluteString ?? "")
        }
        set(pushServer, settings.pushServer ?? DesktopSettings.defaultPushServer)
        set(streamServer, settings.streamServer)
    }

    func applyServers() {
        do {
            try store.setServers(push: text(of: pushServer), stream: text(of: streamServer))
            show(translate("Saved."))
            directory = nil
            loadDirectoryIfNeeded()
            loadRooms()
        } catch {
            show(error)
        }
    }
}

extension Result where Failure == any Error {
    init(catching body: () async throws -> Success) async {
        do {
            self = .success(try await body())
        } catch {
            self = .failure(error)
        }
    }
}

setlocale(LC_ALL, "")
bindtextdomain(textDomain, ProcessInfo.processInfo.environment["SPACESTATE_LOCALEDIR"] ?? "/usr/share/locale")
bind_textdomain_codeset(textDomain, "UTF-8")

exit(SettingsApp().run())
