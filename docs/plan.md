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

One application, `spacestate-desktop`. It is a GTK 4 `GApplication` with the
app id `net.grafixmafia.SpaceState` and runs as a single instance in the
background:

```
SpaceStateKit (ChangeFeed, reads) ──► Core ──► Notifier (GNotification)
                                        │  ──► Tray (SNI + dbusmenu over GDBus)
                                        └──► Settings window (GTK 4 / libadwaita)
```

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
- **Settings window** (GTK 4 / libadwaita):
  - search the SpacePush directory and add spaces,
  - choose Mainframe rooms,
  - autostart on/off,
  - push server (advanced).

  Launching the app again (launcher, `.desktop` entry) opens this window.
- **Configuration** lives in `$XDG_CONFIG_HOME/spacestate/`. The saved spaces in
  `spaces` are shared with SpaceStateCLI. Rooms and app settings go into a new
  `desktop.json`.
- **Headless:** `spacestate-desktop --no-tray` for setups that only want
  notifications. `spacestate notify` from SpaceStateCLI remains the minimal
  option without GTK.

Everything uses GLib/GIO/GTK, which every desktop listed above provides, so a
single dependency stack covers notifications, D-Bus, the tray and the window.

### Swift and GTK

Swift calls C directly. Two options, decided by spike P1:
- **adwaita-swift** (SwiftUI-like declarative API for libadwaita; moved to
  git.aparoksha.dev, last GitHub release 0.2.6 in 2024). It saves boilerplate,
  but its maintenance and how it fits a background app with SNI are open.
- **Own thin C bindings:** a system library target for `gtk4`, `libadwaita-1`
  and `gio-2.0` through pkg-config, plus small Swift wrappers for the few
  widgets the settings window needs. More code, but no dependency risk.

Either way, GTK code stays in a thin layer, and the logic stays in Core.

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
  - build and test in `swift:6.2-noble` with GTK 4 / libadwaita dev packages,
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
| P4 | Settings window: directory search, rooms, autostart, single instance | spaces managed without editing files |
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
| D2 | GTK binding | **Decided:** decide after spike P1: adwaita-swift if it handles a background app with SNI cleanly, otherwise own thin bindings |
| D3 | Language of texts | **Decided:** English first plus gettext from the start; German as the first translation |
| D4 | (later) GNOME without the AppIndicator extension | No tray. Notifications plus launcher and settings; show a hint to the extension in settings |
| D5 | XEmbed-only trays (i3bar, polybar) | Document `snixembed`; no own XEmbed code |
| D6 | Minimum versions | GTK 4.12, libadwaita 1.4, libnotify not needed; Swift 6.2 |
| D7 | License | MIT, as the other SpaceState repositories |
