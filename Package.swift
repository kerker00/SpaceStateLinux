// swift-tools-version: 6.2
import PackageDescription
import Foundation

// Local override for developing against a SpaceStateKit checkout; releases use the pinned tag.
let localKit = ProcessInfo.processInfo.environment["SPACESTATEKIT_PATH"]
let package = Package(
    name: "SpaceStateLinux",
    dependencies: [
        localKit.map { .package(path: $0) }
            ?? .package(url: "https://github.com/kerker00/SpaceStateKit.git", exact: "0.4.0"),
    ],
    targets: [
        // Configuration, current states and notification decisions; no GLib or GTK.
        .target(name: "SpaceStateCore", dependencies: [
            .product(name: "SpaceAPI", package: "SpaceStateKit"),
            .product(name: "MainframeStatus", package: "SpaceStateKit"),
            .product(name: "SpacePushClient", package: "SpaceStateKit"),
        ]),
        .testTarget(name: "SpaceStateCoreTests", dependencies: [
            "SpaceStateCore",
            .product(name: "SpaceAPI", package: "SpaceStateKit"),
            .product(name: "SpacePushClient", package: "SpaceStateKit"),
        ]),
    ]
)
