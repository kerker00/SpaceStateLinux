import CGtk
import Foundation
import SpaceStateCore

// spacestate-settings: the window that manages what spacestate-desktop follows. It only writes
// the configuration files; the service notices the change and reloads. All logic is in Core.

let version = "0.1.0"

/// Lives for the whole process. All fields are used on the GLib main loop only.
final class SettingsApp: @unchecked Sendable {
    let app: UnsafeMutablePointer<GtkApplication>
    let store = SettingsStore()
    var userAgent: String { "spacestate-settings/\(version)" }
    var window: Widget?
    var search: Widget!
    var spacesList: Widget!
    var spacesScroller: Widget!
    var roomsList: Widget!
    var roomsPage: Widget!
    var autostart: Widget!
    var pushServer: Widget!
    var streamServer: Widget!
    var statusLabel: Widget!
    /// Nil until loaded, and again after a failure, so the next search tries again.
    var directory: [SpaceChoice]?
    var loadingDirectory = false
    var rooms: [RoomChoice] = []
    var roomsFailed = false
    /// What the lists show, to notice when another program changes the files.
    var shownSpaces: [SavedSpace] = []
    var shownRooms: [DesktopSettings.Room] = []
    var monitor: UnsafeMutablePointer<GFileMonitor>?
    var refreshScheduled = false
    var serviceState: Widget!
    var startService: Widget!
    var serviceHintShown = false

    init() {
        app = gtk_application_new("net.grafixmafia.SpaceState.Settings", GApplicationFlags(rawValue: 0))
        g_application_add_main_option(gApplication, "version", 0, GOptionFlags(rawValue: 0), G_OPTION_ARG_NONE,
                                      "Show the version", nil)
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
        spacesScroller = widget("spaces_scroller")
        roomsList = widget("rooms")
        roomsPage = widget("rooms_page")
        autostart = widget("autostart")
        pushServer = widget("push_server")
        streamServer = widget("stream_server")
        statusLabel = widget("status")
        serviceState = widget("service_state")
        startService = widget("start_service")

        on(search, "search-changed") { [unowned self] in
            self.loadDirectoryIfNeeded()
            self.renderSpaces()
        }
        gtk_switch_set_active(OpaquePointer(autostart), store.autostart ? 1 : 0)
        onNotify(autostart, "active") { [unowned self] in self.autostartChanged() }
        on(widget("apply_servers"), "clicked") { [unowned self] in self.applyServers() }
        on(startService, "clicked") { [unowned self] in self.startBackgroundService() }

        loadServers()
        renderSpaces()
        renderRooms()
        loadDirectoryIfNeeded()
        loadRooms()
        watchFiles()
        watchService()
        gtk_widget_grab_focus(search)
    }

    /// Lists follow other programs, such as `spacestate add`, a moment after they write.
    func watchFiles() {
        let directory = store.spacesFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = g_file_new_for_path(directory.path)
        monitor = g_file_monitor_directory(file, GFileMonitorFlags(rawValue: 0), nil, nil)
        g_object_unref(UnsafeMutableRawPointer(file))
        guard let monitor else { return }
        let changed: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
                                     UInt32, UnsafeMutableRawPointer?) -> Void = { _, _, _, _, data in
            SettingsApp.from(data).scheduleRefresh()
        }
        g_signal_connect_data(monitor, "changed", unsafeBitCast(changed, to: GCallback.self),
                              Unmanaged.passUnretained(self).toOpaque(), nil, GConnectFlags(rawValue: 0))
    }

    static func from(_ data: UnsafeMutableRawPointer?) -> SettingsApp {
        Unmanaged<SettingsApp>.fromOpaque(data!).takeUnretainedValue()
    }

    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        let fire: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { data in
            let app = SettingsApp.from(data)
            app.refreshScheduled = false
            app.refresh()
            return 0
        }
        g_timeout_add(300, fire, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Only when the content differs, so a change made in this window does not rebuild its rows.
    func refresh() {
        if let spaces = try? store.spaces(), spaces != shownSpaces { renderSpaces() }
        if let followed = try? store.settings().rooms, followed != shownRooms { renderRooms() }
    }

    /// The window only writes files, so without the service nothing would happen.
    func watchService() {
        let appeared: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { _, _, _, data in
            SettingsApp.from(data).serviceChanged(running: true)
        }
        let vanished: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { _, _, data in
            SettingsApp.from(data).serviceChanged(running: false)
        }
        g_bus_watch_name(G_BUS_TYPE_SESSION, "net.grafixmafia.SpaceState", GBusNameWatcherFlags(rawValue: 0), appeared, vanished,
                         Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    func serviceChanged(running: Bool) {
        gtk_label_set_text(OpaquePointer(serviceState), running ? translate("The background service is running.")
                                                                : translate("The background service is not running."))
        gtk_widget_set_visible(startService, running ? 0 : 1)
        if running, serviceHintShown {
            show("")
        } else if !running {
            show(translate("Nothing is followed while the background service is not running. Start it under General."))
        }
        serviceHintShown = !running
    }

    func startBackgroundService() {
        guard isInstalled("spacestate-desktop"), g_spawn_command_line_async("spacestate-desktop", nil) != 0 else {
            show(translate("spacestate-desktop is not on your PATH, so it cannot be started."))
            return
        }
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
                    self.renderSpaces()
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
        shownSpaces = followed
        updateRoomsPage()
        let query = text(of: search)
        let rows = SpaceChoice.rows(query, directory: directory ?? [], followed: followed)
        for item in rows { gtk_list_box_append(list, spaceRow(item.choice, followed: item.followed)) }
        if directory == nil {
            gtk_list_box_append(list, row(loadingDirectory ? translate("Loading the directory…")
                                                           : translate("Could not load the directory. Search again to retry.")))
        } else if rows.isEmpty {
            gtk_list_box_append(list, row(translate("No space with this name or place in the directory.")))
        }
        scrollSpacesToTop()
    }

    /// A rebuilt list starts at the top, where the followed spaces are. It happens once the
    /// new rows are laid out, as GTK otherwise keeps a position from the old ones.
    func scrollSpacesToTop() {
        let top: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { data in
            let app = SettingsApp.from(data)
            gtk_adjustment_set_value(gtk_scrolled_window_get_vadjustment(OpaquePointer(app.spacesScroller)), 0)
            return 0 // G_SOURCE_REMOVE
        }
        g_idle_add(top, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Changes the row itself rather than rebuilding the list, so it stays where it is.
    func spaceRow(_ choice: SpaceChoice, followed: Bool) -> Widget {
        var isFollowed = followed
        let title: () -> String = { isFollowed ? translate("Remove") : translate("Add") }
        let button = gtk_button_new_with_label(title())!
        on(button, "clicked") { [unowned self] in
            do {
                if isFollowed {
                    try self.store.remove(choice.endpoint)
                } else {
                    try self.store.add(SavedSpace(endpoint: choice.endpoint, name: choice.name))
                }
                isFollowed.toggle()
                gtk_button_set_label(UnsafeMutableRawPointer(button).assumingMemoryBound(to: GtkButton.self), title())
                self.shownSpaces = try self.store.spaces()
                self.updateRoomsPage()
                self.show("")
            } catch {
                self.show(error)
            }
        }
        return row(choice.name, subtitle: choice.place, control: button)
    }

    func updateRoomsPage() {
        gtk_widget_set_visible(roomsPage, RoomChoice.areOffered(spaces: (try? store.spaces()) ?? []) ? 1 : 0)
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
                    self.roomsFailed = false
                case .failure:
                    self.roomsFailed = true
                }
                self.renderRooms()
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
        shownRooms = followed
        updateRoomsPage()
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
                    self.shownRooms = try self.store.settings().rooms
                    self.updateRoomsPage()
                    self.show("")
                } catch {
                    self.show(error)
                }
            }
            gtk_list_box_append(list, check)
        }
        if rows.isEmpty {
            gtk_list_box_append(list, row(roomsFailed ? translate("Could not load the Mainframe rooms.")
                                                      : translate("Loading the rooms…")))
        }
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
            renderSpaces()
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

if CommandLine.arguments.contains("--version") {
    print(version)
    exit(0)
}

exit(SettingsApp().run())
