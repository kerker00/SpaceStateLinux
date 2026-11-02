// swift-tools-version: 6.2
import PackageDescription
import Foundation

// Local override for developing against a SpaceStateKit checkout; releases use the pinned tag.
let localKit = ProcessInfo.processInfo.environment["SPACESTATEKIT_PATH"]
let package = Package(
    name: "SpaceStateLinux",
    products: [.executable(name: "spacestate-desktop", targets: ["SpaceStateDesktop"])],
    dependencies: [
        localKit.map { .package(path: $0) }
            ?? .package(url: "https://github.com/kerker00/SpaceStateKit.git", exact: "0.4.1"),
    ],
    targets: [
        // GLib and GIO headers through pkg-config; the service needs no widget toolkit.
        .systemLibrary(name: "CGio", pkgConfig: "gio-2.0", providers: [.apt(["libglib2.0-dev"]), .yum(["glib2-devel"])]),
        // StatusNotifierItem and com.canonical.dbusmenu over GDBus, in C because GVariant
        // construction relies on variadic functions that Swift cannot call.
        .target(name: "CStatusNotifier", dependencies: ["CGio"]),
        // Configuration, current states and notification decisions; no GLib or GTK.
        .target(name: "SpaceStateCore", dependencies: [
            .product(name: "SpaceAPI", package: "SpaceStateKit"),
            .product(name: "MainframeStatus", package: "SpaceStateKit"),
            .product(name: "SpacePushClient", package: "SpaceStateKit"),
        ]),
        // The background service: notifications and a tray icon for the followed spaces and rooms.
        .executableTarget(name: "SpaceStateDesktop", dependencies: ["SpaceStateCore", "CGio", "CStatusNotifier"]),
        .testTarget(name: "SpaceStateCoreTests", dependencies: [
            "SpaceStateCore",
            .product(name: "SpaceAPI", package: "SpaceStateKit"),
            .product(name: "MainframeStatus", package: "SpaceStateKit"),
            .product(name: "SpacePushClient", package: "SpaceStateKit"),
        ]),
    ]
)
