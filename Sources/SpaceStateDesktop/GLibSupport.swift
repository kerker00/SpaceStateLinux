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

/// Links to the `.svg` files in a new directory per run. The Omarchy shell loads an icon
/// outside a known theme directory from `<IconThemePath>/<IconName>` without an extension,
/// and caches by that path. Plasma looks for `<IconThemePath>/<IconName>.svg`, so each icon
/// is linked under both names. Hosts that find the name in the theme do not use it.
func publishIcons(from source: String) -> String? {
    let files = FileManager.default
    let runtime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] ?? NSTemporaryDirectory()
    let base = URL(filePath: runtime).appending(path: "spacestate-icons")
    let directory = base.appending(path: String(Int(Date().timeIntervalSince1970)))
    let sourceDirectory = URL(filePath: source)
    guard let names = try? files.contentsOfDirectory(atPath: source) else {
        log("SPACESTATE_ICONDIR: cannot read \(source).")
        return nil
    }
    try? files.removeItem(at: base)
    try? files.createDirectory(at: directory, withIntermediateDirectories: true)
    for name in names where name.hasSuffix(".svg") {
        for link in [String(name.dropLast(4)), name] {
            try? files.createSymbolicLink(at: directory.appending(path: link),
                                          withDestinationURL: sourceDirectory.appending(path: name))
        }
    }
    return directory.path
}

/// A lost log must not end the service, for example after the terminal it started from closed.
func log(_ line: String) {
    try? FileHandle.standardError.write(contentsOf: Data("\(line)\n".utf8))
}
