# Plan: SpaceState for the Linux desktop

Status: draft for review · branch `docs/initial-plan` · diagram: [architecture.drawio](architecture.drawio)

## Goal and scope

A Linux desktop app that
1. shows a **desktop notification** when a followed space or Mainframe room opens or closes,
2. shows the current state in a **tray/panel icon** with a menu, and
3. has a **settings window** to choose spaces and rooms and to switch autostart on or off.

A main window with lists, details, map and sensors, as in the iOS/macOS app, is
out of scope for now. The architecture leaves room for it.

First target is **Hyprland** (Omarchy). After that come KDE Plasma, XFCE,
GNOME, the Wayland tilers (Sway, niri, river) and X11 tilers (i3, bspwm,
awesome, qtile). Distributions: Arch first, then Fedora, Debian/Ubuntu and
others through Flatpak. Architectures: x86_64 and aarch64.

## What differs between desktops

Most of the app is the same everywhere. Only three integration points differ:

| Desktop | Notifications | Tray icon (StatusNotifierItem) | Autostart |
| --- | --- | --- | --- |
| Hyprland (Omarchy 4) | Omarchy shell (quickshell); otherwise mako, swaync, dunst | Omarchy shell (quickshell) provides the StatusNotifierWatcher; otherwise Waybar `tray` | XDG autostart via uwsm, systemd user unit, or `exec-once` |
| Sway, niri, river | mako, swaync, dunst | Waybar or ironbar `tray` | XDG autostart via uwsm, systemd user unit, or compositor config |
| KDE Plasma | native | native | XDG autostart |
| XFCE | xfce4-notifyd | panel "Status Tray" plugin | XDG autostart |
| GNOME | native | only with the AppIndicator extension (preinstalled on Ubuntu, not on Fedora) | XDG autostart; Background portal under Flatpak |
| Cinnamon, MATE, Budgie | native | to verify (Xapp / Ayatana applets) | XDG autostart |
| i3, bspwm, awesome (X11) | dunst | i3bar/polybar speak only XEmbed: needs the `snixembed` bridge; qtile has a StatusNotifier widget | `exec` in WM config, `dex`, or systemd user unit |

Consequences:
- **Notifications** work everywhere through `org.freedesktop.Notifications`, or
  the notification portal under Flatpak. GIO's `GNotification` picks the right one.
- The **tray** uses StatusNotifierItem (SNI) only. There is no XEmbed tray of
  our own; on XEmbed-only bars the documented route is `snixembed`.
- **Without any tray** (plain GNOME, a bar without a tray) the app must still be
  usable: notifications keep working, and the settings window opens from the
  app launcher. Waybar users can also use the existing
  `spacestate watch --waybar --push` module instead of the tray.
- **Autostart** is written as an XDG autostart entry, which most desktops honour,
  or requested from the Background portal under Flatpak. A systemd user unit is
  documented for tiling setups.

## Architecture

Which desktops we support depends on the D-Bus standards above, not on a
widget toolkit. Only the settings window needs one. So the app is split into
two processes:

```
spacestate-desktop (background service, GIO only, no widget toolkit)
  SpaceStateKit (ChangeFeed, reads) ──► Core ──► Notifier (GNotification)
                                          ├──► Tray (SNI + dbusmenu over GDBus)
                                          └──► watches the config files

spacestate-settings (separate process, started on demand)
  Settings window (plain GTK 4, GtkBuilder .ui files) ──► writes the config files
```

- **`spacestate-desktop`** is a `GApplication` (GIO) with the app id
  `net.grafixmafia.SpaceState`. It runs as a single instance in the
  background and does not load GTK, so it runs the same way on every desktop
  and window manager and needs little memory.
- **`spacestate-settings`** is a `GtkApplication` with the app id
  `net.grafixmafia.SpaceState.Settings`. The tray menu ("Settings…"), a click
  on a notification and the launcher entry start it. It writes the
  configuration files; the service notices the change through `GFileMonitor`
  and reloads. No own D-Bus API is needed for that.
- The UI is replaceable: a Qt/QML settings window for KDE could be added later
  without touching the service. SpaceStateCLI edits the same `spaces` file.

- **Core**, a Swift module without GTK and fully unit-tested:
  - configuration,
  - the followed subscriptions (spaces and Mainframe rooms),
  - the current states,
  - the ChangeFeed loop with resync through the read API after every connection,
  - deciding what to notify.
- **Notifier:** `GNotification` with one id per topic, so a newer state replaces
  the older one. Clicking a notification opens the settings window, or later the
  space's website.
- **Tray:** a StatusNotifierItem plus a `com.canonical.dbusmenu` menu,
  implemented over GDBus (GIO), so no GTK 3 library like libayatana-appindicator
  is needed. The icon shows open, closed or unknown; the menu has one line per
  followed space or room, "Settings…" and "Quit". If no StatusNotifierWatcher
  is present, the tray stays off and nothing fails.
- **Settings window** (plain GTK 4, separate process):
  - search the SpacePush directory and add spaces,
  - choose Mainframe rooms,
  - autostart on/off,
  - push server (advanced).

  The launcher entry starts this window; the service is started by autostart.
- **Configuration** lives in `$XDG_CONFIG_HOME/spacestate/`. The saved spaces in
  `spaces` are shared with SpaceStateCLI. Rooms and app settings go into a new
  `desktop.json`.
- **Headless:** `spacestate-desktop --no-tray` for setups that only want
  notifications. `spacestate notify` from SpaceStateCLI remains the minimal
  option without GTK.

Everything uses GLib/GIO, plus GTK 4 for the window. Every desktop listed
above provides them, so one dependency stack covers notifications, D-Bus, the
tray and the window.

### Swift and GTK (decision D2)

Swift calls C directly. Spike P1 showed that a background app with tray,
notifications and a window works from Swift over C interop: SNI and dbusmenu
in a small C module (GVariant construction needs variadic C functions), the
rest from Swift. Decision:

- **Own thin bindings:** a system library target for `gtk4` and `gio-2.0`
  through pkg-config, plus small Swift wrappers for the widgets the settings
  window needs.
- **GtkBuilder `.ui` files** describe the window declaratively. Swift only
  loads them and connects signals, which keeps the wrapper code small.
- **Plain GTK 4, no libadwaita.** libadwaita always looks like GNOME and ignores
  the desktop theme. Plain GTK 4 follows the theme (Breeze on KDE, the XFCE
  theme, Omarchy's GTK theme) and fits more desktops.

Frameworks evaluated (November 2026):

| Framework | Finding |
| --- | --- |
| [adwaita-swift](https://codeberg.org/aparoksha/adwaita-swift) | Last release 0.1.0 in October 2024; dependencies on unversioned `main` branches; needs Swift 6.3 and build plugins; no background mode, tray or notifications; creates its own SQLite file. Not used. |
| [swift-cross-ui](https://github.com/moreSwift/swift-cross-ui) | Active (v0.10.0, September 2026), MIT, versioned dependencies, SwiftUI-like API on plain GTK 4. Still before 1.0 and without background or tray support. Watched as an option for the settings window. |
| [SwiftGtk](https://github.com/rhx/SwiftGtk) | Generates the whole GTK API with gir2swift; heavy for one window. Not used. |
| Qt/QML | Fits KDE best, but means C++ interop or a second language. Possible later as an extra settings frontend. |

GTK code stays in a thin layer, and the logic stays in Core.

## Packaging and platforms

| Channel | When | Notes |
| --- | --- | --- |
| AUR (`spacestate-desktop`, `-git`) | first | Arch/Omarchy; native GTK; Swift runtime with `--static-swift-stdlib` |
| Flatpak (Flathub) | second | GNOME runtime plus `org.freedesktop.Sdk.Extension.swift6` (x86_64, aarch64); notification and Background portals; covers Fedora, Ubuntu, Debian and more |
| Fedora Copr RPM, Debian/Ubuntu `.deb` | later | only if requested; built in CI |

GTK is always linked dynamically from the system or runtime. Only the Swift
runtime is linked statically (`--static-swift-stdlib`), so native packages need
no Swift installation.

## Testing

- **Unit tests** (Swift Testing) for Core:
  - config read/write and shared `spaces` file,
  - subscription changes,
  - resync logic,
  - notification decisions,
  - dbusmenu layout as data.
- **CI:**
  - build and test in `swift:6.2-noble` with GTK 4 dev packages,
  - build the Flatpak with `flatpak-builder`,
  - aarch64 build.
- **Desktop smoke checklist** per desktop, run manually in VMs or live images:
  - notification appears and is replaced,
  - tray icon and menu,
  - settings window opens from the launcher and from the tray,
  - autostart after re-login,
  - behaviour without a tray.

  Hyprland on the development machine first, then KDE, XFCE, GNOME (with and
  without the extension), Sway and i3 with snixembed.
- **End to end** against a local SpacePush with the stream listener enabled,
  using `POST /v1/stream/test`.

## Phases

| Phase | Content | Done when |
| --- | --- | --- |
| P0 | Repo, plan, diagram (this branch) | plan reviewed |
| P1 | Spike on Hyprland: Swift GTK 4 window, `GNotification`, SNI icon in Waybar; decide D2 | small prototype works, decision recorded |
| P2 | Core and notifier: config, ChangeFeed, resync, notifications | notifications on Hyprland from a local and the production SpacePush |
| P3 | Tray: SNI and dbusmenu | icon and menu in Waybar, KDE, XFCE |
| P4 | Settings window as `spacestate-settings`: directory search, rooms, autostart; service reloads on change | spaces managed without editing files |
| P5 | Packaging: AUR, then Flatpak | install on a fresh Arch and a fresh Fedora VM |
| P6 | Desktop matrix: GNOME, Sway/niri, i3, Cinnamon/MATE; fixes and docs | smoke checklist passes, gaps documented |
| P7 | Release 0.1.0 | tagged, packages published |

## Prerequisites in the other repositories

- **SpacePush:** PR #40 merged and released. On Uberspace: the stream listener
  enabled and the `/v1/stream` path backend verified (O1–O3 in the SpacePush plan).
- **SpaceStateKit:** release 0.4.0 with the change stream. Its macOS CI must pass.
- **SpaceStateCLI:** pin updated to Kit 0.4.0. It keeps `notify` and
  `watch --push` as the minimal options.

## Open decisions

| # | Question | Proposal |
| --- | --- | --- |
| D1 | Repository name | **Decided:** `SpaceStateLinux`, app id `net.grafixmafia.SpaceState`, binary `spacestate-desktop` |
| D2 | GTK binding | **Decided after spike P1:** own thin bindings with GtkBuilder `.ui` files, plain GTK 4 without libadwaita; service and settings window as separate processes (see "Swift and GTK") |
| D3 | Language of texts | **Decided:** English first plus gettext from the start; German as the first translation |
| D4 | (later) GNOME without the AppIndicator extension | No tray. Notifications plus launcher and settings; show a hint to the extension in settings |
| D5 | XEmbed-only trays (i3bar, polybar) | Document `snixembed`; no own XEmbed code |
| D6 | Minimum versions | GTK 4.12, GLib 2.76, libnotify not needed; Swift 6.2 |
| D7 | License | MIT, as the other SpaceState repositories |
