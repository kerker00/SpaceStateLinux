# SpaceStateLinux

Linux desktop app for [SpaceState](https://github.com/kerker00/SpaceState): desktop notifications when hackerspaces open or close, a tray/panel icon with their current state, and a settings window.

It builds on [SpaceStateKit](https://github.com/kerker00/SpaceStateKit) and receives changes from [SpacePush](https://github.com/kerker00/SpacePush) through its change stream. First target is Hyprland; GNOME, KDE Plasma, XFCE and other tiling window managers follow.

Status: 0.1.0, source only, tested on Hyprland with the Omarchy shell. Other desktops follow. See [CHANGELOG.md](CHANGELOG.md), [docs/plan.md](docs/plan.md) and [docs/architecture.drawio](docs/architecture.drawio).

## spacestate-desktop

The background service. It follows the SpacePush change stream for your spaces
and rooms and shows a notification when one opens or closes. After every
(re)connection it reads the current states, so a change missed while offline
is shown once. A newer notification for the same space or room replaces the older.
While the stream stays unavailable, or SpacePush refuses it because a saved space is not
in its directory, it reads the states every few minutes instead, so notifications
continue with a delay.

A tray icon (StatusNotifierItem) shows whether anything you follow is open, and
its menu lists each space and room with its state. When neither the stream nor
the read API answers, states are shown as unknown. Without a tray host the service keeps
running and shows notifications only; `--no-tray` leaves the icon out on purpose.

It needs GLib/GIO 2.76 or later and a notification daemon (any desktop, or
mako, swaync, dunst). It does not load GTK.

### Configuration

Both files live in `$XDG_CONFIG_HOME/spacestate/` (default `~/.config/spacestate/`).
The service reloads when they change.

- `spaces`: the saved spaces of [SpaceStateCLI](https://github.com/kerker00/SpaceStateCLI),
  one endpoint per line with an optional `# name`. Add spaces with `spacestate add <name>`
  or edit the file by hand.
- `desktop.json` (optional): Mainframe rooms and the server. Rooms count only while
  Mainframe is in `spaces`.

  ```json
  {
    "rooms": [{"endpoint": "https://status.mainframe.io/api/spaceInfo", "room": "radstelle"}],
    "pushServer": "https://push.grafixmafia.net",
    "streamServer": null
  }
  ```

  `streamServer` is only needed when `/v1/stream` is served elsewhere than `pushServer`.

### Build and run

```sh
swift build -c release
cp .build/release/spacestate-desktop .build/release/spacestate-settings ~/.local/bin/
```

Building needs Swift 6.2 and the GLib and GTK 4 development files, as `spacestate-settings` is in the same package.

To develop against a SpaceStateKit checkout:
`SPACESTATEKIT_PATH=../SpaceStateKit swift build`.

Tray hosts find the icons by name, so install them into the icon theme:

```sh
mkdir -p ~/.local/share/icons/hicolor/scalable/status
cp data/icons/hicolor/scalable/status/*.svg ~/.local/share/icons/hicolor/scalable/status/
```

On the Omarchy shell, restart the shell or log in again if that directory is new.

The Omarchy shell only sees icon directories that existed when it started. During
development, `SPACESTATE_ICONDIR=data/icons/hicolor/scalable/status` uses the
repository's icons without installing them.

Start it with the session through one of:
- XDG autostart (GNOME, KDE Plasma, XFCE, Hyprland with uwsm):
  `cp contrib/net.grafixmafia.SpaceState.desktop ~/.config/autostart/`
- a systemd user unit: see `contrib/spacestate-desktop.service`
- `exec-once = spacestate-desktop` in `hyprland.conf`, or `exec` in Sway or i3

Messages go to stderr (the journal under systemd). Launching it again does not
start a second instance; it says so and exits.

## spacestate-settings

The settings window, a separate program that needs GTK 4.12 or later. The tray menu
and a click on a notification open it, and so does the launcher with
`contrib/net.grafixmafia.SpaceState.Settings.desktop` in `~/.local/share/applications/`.

- **Spaces:** all spaces of the SpacePush directory, yours first. Search by name or place,
  add and remove them.
- **Mainframe Rooms:** once Mainframe is chosen, which rooms notify. The tray menu always
  shows all of them.
- **General:** whether the background service runs, with a button to start it, start
  with the session, and the servers under Advanced.

It only writes the configuration files, and the running service reloads them. Lines
it does not use in `spaces` stay as they are, and a `desktop.json` it cannot read is
reported and left alone. The switch manages an XDG autostart entry; a systemd user
unit or `exec-once` is not shown there.

## Translations

Texts are in English, with gettext catalogues in `po/`. After changing a text, run
`po/update.sh` and translate what is new; `po/check.sh` fails on anything missing.
Without an installed catalogue, `SPACESTATE_LOCALEDIR` points to another locale directory.

## Packages

`packaging/aur/PKGBUILD` builds an Arch package. Its build needs `swift-language`,
which `swift-bin` from the AUR provides.
