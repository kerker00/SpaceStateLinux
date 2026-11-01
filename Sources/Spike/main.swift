import CGtk
import CStatusNotifier
import Foundation

// Spike P1: a background GApplication with a tray icon, notifications and a settings window,
// written against GTK 4 / libadwaita directly through C interop.

final class SpikeApp {
    let app: UnsafeMutablePointer<AdwApplication>
    var window: UnsafeMutablePointer<GtkWidget>?
    var tray: OpaquePointer?
    var open = true

    init() {
        app = adw_application_new("net.grafixmafia.SpaceState", GApplicationFlags(rawValue: 0))
    }

    var gApplication: UnsafeMutablePointer<GApplication> {
        UnsafeMutableRawPointer(app).assumingMemoryBound(to: GApplication.self)
    }

    func run() -> Int32 {
        let context = Unmanaged.passUnretained(self).toOpaque()
        connect(app, "startup", context) { _, data in SpikeApp.from(data).startup() }
        connect(app, "activate", context) { _, data in SpikeApp.from(data).showWindow() }
        return g_application_run(gApplication, CommandLine.argc, CommandLine.unsafeArgv)
    }

    static func from(_ data: UnsafeMutableRawPointer?) -> SpikeApp {
        Unmanaged<SpikeApp>.fromOpaque(data!).takeUnretainedValue()
    }

    /// Keeps the application running without windows, like a tray app.
    func startup() {
        g_application_hold(gApplication)
        let context = Unmanaged.passUnretained(self).toOpaque()
        // A click opens the menu; the window opens only from "Settings…".
        tray = sn_item_new("spacestate", "SpaceState", icon, nil, { id, data in
            SpikeApp.from(data).menuClicked(Int(id))
        }, context)
        sn_item_set_icon_theme_path(tray, Self.iconDirectory)
        updateMenu()
        print("tray watcher present: \(sn_item_has_watcher(tray))")
        notify(title: "SpaceState", body: "Spike is running in the background.")
    }

    /// Monochrome icons, tinted by the panel like the other tray icons.
    var icon: String { "net.grafixmafia.SpaceState-\(open ? "open" : "closed")-symbolic" }

    /// Spike only: the icons from the repository. An installed app puts them into hicolor.
    /// The Omarchy shell (quickshell) loads `<IconThemePath>/<IconName>` without an
    /// extension when the name is not in a theme, so the directory holds links
    /// without ".svg"; Qt detects SVG from the content.
    static let iconDirectory: String = {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "data/icons/hicolor/scalable/status")
        let runtime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] ?? NSTemporaryDirectory()
        // A new directory per run: the shell caches icons by URL, which includes this path.
        let files = FileManager.default
        let base = URL(fileURLWithPath: runtime).appending(path: "spacestate-icons")
        try? files.removeItem(at: base)
        let directory = base.appending(path: String(Int(Date().timeIntervalSince1970)))
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in (try? files.contentsOfDirectory(atPath: source.path)) ?? [] where name.hasSuffix(".svg") {
            let link = directory.appending(path: String(name.dropLast(4)))
            try? files.removeItem(at: link)
            try? files.createSymbolicLink(at: link, withDestinationURL: source.appending(path: name))
        }
        return directory.path
    }()

    func updateMenu() {
        let items: [(Int32, String, Bool)] = [
            (1, "Mainframe — \(open ? "open" : "closed")", false),
            (2, "", true),
            (3, "Toggle state", true),
            (4, "Settings…", true),
            (5, "Send test notification", true),
            (6, "", true),
            (7, "Quit", true),
        ]
        // Keep the C strings alive while the C side copies them.
        let labels = items.map { strdup($0.1)! }
        defer { labels.forEach { free($0) } }
        var menu = zip(items, labels).map { item, label in
            SnMenuItem(id: item.0, label: UnsafePointer(label), enabled: item.2)
        }
        sn_item_set_menu(tray, &menu, Int32(menu.count))
        sn_item_set_icon(tray, icon, "Mainframe is \(open ? "open" : "closed")")
    }

    func menuClicked(_ id: Int) {
        switch id {
        case 3:
            open.toggle()
            updateMenu()
            notify(title: "Mainframe", body: open ? "Open" : "Closed")
        case 4: showWindow()
        case 5: notify(title: "SpaceState", body: "Test notification from the spike.")
        case 7: g_application_quit(gApplication)
        default: break
        }
    }

    /// One id per topic: a newer notification replaces the older one.
    func notify(title: String, body: String) {
        let notification = g_notification_new(title)
        g_notification_set_body(notification, body)
        g_application_send_notification(gApplication, "mainframe", notification)
        g_object_unref(UnsafeMutableRawPointer(notification))
    }

    func showWindow() {
        if window == nil {
            let window = adw_application_window_new(UnsafeMutableRawPointer(app).assumingMemoryBound(to: GtkApplication.self))!
            gtk_window_set_title(asWindow(window), "SpaceState")
            gtk_window_set_default_size(asWindow(window), 420, 320)
            gtk_window_set_hide_on_close(asWindow(window), 1)
            let toolbar = adw_toolbar_view_new()!
            adw_toolbar_view_add_top_bar(OpaquePointer(toolbar), adw_header_bar_new())
            let page = adw_status_page_new()!
            adw_status_page_set_icon_name(OpaquePointer(page), "preferences-system-symbolic")
            adw_status_page_set_title(OpaquePointer(page), "SpaceState")
            adw_status_page_set_description(OpaquePointer(page), "Settings will live here. Closing hides the window; the tray keeps running.")
            adw_toolbar_view_set_content(OpaquePointer(toolbar), page)
            adw_application_window_set_content(UnsafeMutableRawPointer(window).assumingMemoryBound(to: AdwApplicationWindow.self), toolbar)
            self.window = window
        }
        gtk_window_present(asWindow(window!))
    }

    func asWindow(_ widget: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GtkWindow> {
        UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkWindow.self)
    }
}

/// `g_signal_connect` is a C macro, so this calls `g_signal_connect_data` for a (instance, data) signal.
func connect(_ instance: UnsafeMutableRawPointer, _ signal: String, _ data: UnsafeMutableRawPointer,
             _ handler: @escaping @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void) {
    g_signal_connect_data(instance, signal, unsafeBitCast(handler, to: GCallback.self), data, nil, GConnectFlags(rawValue: 0))
}

let spike = SpikeApp()
exit(spike.run())
