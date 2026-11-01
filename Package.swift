// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SpaceStateLinux",
    targets: [
        // GTK 4 and libadwaita headers through pkg-config.
        .systemLibrary(name: "CGtk", pkgConfig: "libadwaita-1", providers: [.apt(["libadwaita-1-dev"]), .yum(["libadwaita-devel"])]),
        // StatusNotifierItem and com.canonical.dbusmenu over GDBus, in C because GVariant
        // construction relies on variadic functions that Swift cannot call.
        .target(name: "CStatusNotifier", dependencies: ["CGtk"]),
        // Spike P1: background GApplication with a tray icon, notifications and a window.
        .executableTarget(name: "Spike", dependencies: ["CGtk", "CStatusNotifier"]),
    ]
)
