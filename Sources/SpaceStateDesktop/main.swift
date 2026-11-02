import CGio
import Foundation
import SpaceStateCore

// spacestate-desktop: a background GApplication (GIO only) that shows a notification
// when a followed space or Mainframe room opens or closes.

let version = "0.1.0-dev"

/// Lives for the whole process. All fields are used on the GLib main loop only.
final class DesktopApp: @unchecked Sendable {
    let app: UnsafeMutablePointer<GApplication>
    var configuration: Configuration?
    var task: Task<Void, Never>?
    var monitor: UnsafeMutablePointer<GFileMonitor>?
    var reloadScheduled = false

    init() {
        app = g_application_new("net.grafixmafia.SpaceState", GApplicationFlags(rawValue: 0))
    }

    var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    static func from(_ data: UnsafeMutableRawPointer?) -> DesktopApp {
        Unmanaged<DesktopApp>.fromOpaque(data!).takeUnretainedValue()
    }

    func run() -> Int32 {
        let startup: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
            DesktopApp.from(data).startup()
        }
        // A second launch only activates this instance; the settings window will open here (P4).
        let activate: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, _ in }
        connect(app, "startup", context, startup)
        connect(app, "activate", context, activate)
        return g_application_run(app, CommandLine.argc, CommandLine.unsafeArgv)
    }

    /// Runs once in the primary instance: stays in the background and starts following.
    func startup() {
        g_application_hold(app)
        let quit: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { data in
            g_application_quit(DesktopApp.from(data).app)
            return 0
        }
        g_unix_signal_add(SIGTERM, quit, context)
        g_unix_signal_add(SIGINT, quit, context)
        watchConfiguration()
        reload()
    }

    /// Reloads when a file in the config directory changes, e.g. after `spacestate add`.
    func watchConfiguration() {
        let directory = Paths.configDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = g_file_new_for_path(directory.path)
        monitor = g_file_monitor_directory(file, GFileMonitorFlags(rawValue: 0), nil, nil)
        g_object_unref(UnsafeMutableRawPointer(file))
        guard let monitor else {
            log("Cannot watch \(directory.path); restart the app after changing the configuration.")
            return
        }
        let changed: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
                                     UInt32, UnsafeMutableRawPointer?) -> Void = { _, _, _, _, data in
            DesktopApp.from(data).scheduleReload()
        }
        connect(monitor, "changed", context, changed)
    }

    /// Editors and atomic writes cause several events; one reload follows shortly after the last.
    func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        let fire: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { data in
            let app = DesktopApp.from(data)
            app.reloadScheduled = false
            app.reload()
            return 0
        }
        g_timeout_add(300, fire, context)
    }

    func reload() {
        let loaded = Configuration.load()
        guard loaded != configuration else { return }
        loaded.problems.forEach(log)
        configuration = loaded
        let service = DesktopService(
            configuration: loaded, userAgent: "spacestate-desktop/\(version)",
            texts: AlertTexts(translate: translate),
            show: { [unowned self] alert in onMainLoop { self.notify(alert) } },
            log: log)
        // The previous stream ends before the next one opens.
        let previous = task
        previous?.cancel()
        task = Task {
            await previous?.value
            await service.run()
        }
    }

    func notify(_ alert: Alert) {
        let notification = g_notification_new(alert.summary)
        g_notification_set_body(notification, alert.body)
        g_application_send_notification(app, alert.id, notification)
        g_object_unref(UnsafeMutableRawPointer(notification))
    }

    /// Ends the stream before the process exits.
    func stop() {
        guard let task else { return }
        task.cancel()
        let done = DispatchSemaphore(value: 0)
        Task {
            await task.value
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
    }
}

setlocale(LC_ALL, "")
bindtextdomain(textDomain, ProcessInfo.processInfo.environment["SPACESTATE_LOCALEDIR"] ?? "/usr/share/locale")
bind_textdomain_codeset(textDomain, "UTF-8")
g_set_application_name("SpaceState")

let desktop = DesktopApp()
let status = desktop.run()
desktop.stop()
exit(status)
