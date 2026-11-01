import CGio
import Foundation

/// `g_signal_connect` is a C macro, so this calls `g_signal_connect_data`.
func connect<Handler>(_ instance: UnsafeMutableRawPointer, _ signal: String, _ data: UnsafeMutableRawPointer,
                      _ handler: Handler) {
    g_signal_connect_data(instance, signal, unsafeBitCast(handler, to: GCallback.self), data, nil, GConnectFlags(rawValue: 0))
}

/// Runs `body` once on the GLib main loop, where all GIO calls of the app happen.
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

func log(_ line: String) {
    FileHandle.standardError.write(Data("\(line)\n".utf8))
}
