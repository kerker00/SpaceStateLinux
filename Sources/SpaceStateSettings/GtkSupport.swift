import CGtk
import Foundation

typealias Widget = UnsafeMutablePointer<GtkWidget>

/// A Swift closure as signal data, released when the signal is disconnected.
private final class Handler {
    let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
}

private let release: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<GClosure>?) -> Void = { data, _ in
    Unmanaged<Handler>.fromOpaque(data!).release()
}

/// `g_signal_connect` is a C macro, so this calls `g_signal_connect_data`.
private func connect(_ instance: UnsafeMutableRawPointer, _ signal: String, _ callback: GCallback, _ body: @escaping () -> Void) {
    g_signal_connect_data(instance, signal, callback, Unmanaged.passRetained(Handler(body)).toOpaque(),
                          unsafeBitCast(release, to: GClosureNotify.self), GConnectFlags(rawValue: 0))
}

/// For signals without arguments, such as `clicked` and `toggled`.
func on(_ instance: UnsafeMutableRawPointer, _ signal: String, _ body: @escaping () -> Void) {
    let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
        Unmanaged<Handler>.fromOpaque(data!).takeUnretainedValue().body()
    }
    connect(instance, signal, unsafeBitCast(callback, to: GCallback.self), body)
}

/// For `notify::<property>`, which passes the property's description as an argument.
func onNotify(_ instance: UnsafeMutableRawPointer, _ property: String, _ body: @escaping () -> Void) {
    let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, _, data in
        Unmanaged<Handler>.fromOpaque(data!).takeUnretainedValue().body()
    }
    connect(instance, "notify::\(property)", unsafeBitCast(callback, to: GCallback.self), body)
}

/// Runs `body` once on the GLib main loop, where all GTK calls of the app happen.
func onMainLoop(_ body: @escaping @Sendable () -> Void) {
    final class Box {
        let body: @Sendable () -> Void
        init(_ body: @escaping @Sendable () -> Void) { self.body = body }
    }
    let box = Unmanaged.passRetained(Box(body)).toOpaque()
    g_main_context_invoke_full(nil, 0 /* G_PRIORITY_DEFAULT */, { data in
        Unmanaged<Box>.fromOpaque(data!).takeRetainedValue().body()
        return 0 // G_SOURCE_REMOVE
    }, box, nil)
}

/// Translates through gettext with the app's text domain. Without a translation
/// gettext returns its argument, so the result is copied while that C string lives.
func translate(_ text: String) -> String {
    text.withCString { String(cString: dgettext(textDomain, $0)) }
}

let textDomain = "spacestate"

func isInstalled(_ program: String) -> Bool {
    guard let path = g_find_program_in_path(program) else { return false }
    g_free(path)
    return true
}

/// The text of an entry or search entry, both of which are `GtkEditable`.
func text(of editable: Widget) -> String {
    String(cString: gtk_editable_get_text(OpaquePointer(editable)))
}

/// A list row: a label that takes the free space, and optionally a control at its end.
func row(_ title: String, control: Widget? = nil) -> Widget {
    let box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12)!
    gtk_widget_set_margin_start(box, 12)
    gtk_widget_set_margin_end(box, 6)
    gtk_widget_set_margin_top(box, 6)
    gtk_widget_set_margin_bottom(box, 6)
    let label = gtk_label_new(title)!
    gtk_widget_set_hexpand(label, 1)
    gtk_label_set_xalign(OpaquePointer(label), 0)
    gtk_label_set_ellipsize(OpaquePointer(label), PANGO_ELLIPSIZE_END)
    gtk_box_append(UnsafeMutableRawPointer(box).assumingMemoryBound(to: GtkBox.self), label)
    if let control {
        gtk_box_append(UnsafeMutableRawPointer(box).assumingMemoryBound(to: GtkBox.self), control)
    }
    return box
}
