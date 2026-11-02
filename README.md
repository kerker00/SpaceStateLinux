# SpaceStateLinux

Linux desktop app for [SpaceState](https://github.com/kerker00/SpaceState): desktop notifications when hackerspaces open or close, a tray/panel icon with their current state, and a settings window.

It builds on [SpaceStateKit](https://github.com/kerker00/SpaceStateKit) and receives changes from [SpacePush](https://github.com/kerker00/SpacePush) through its change stream. First target is Hyprland; GNOME, KDE Plasma, XFCE and other tiling window managers follow.

Status: in development (phase P3: tray icon). See [docs/plan.md](docs/plan.md) and [docs/architecture.drawio](docs/architecture.drawio).

## spacestate-desktop

The background service. It follows the SpacePush change stream for your spaces
and rooms and shows a notification when one opens or closes. After every
(re)connection it reads the current states, so a change missed while offline
is shown once. A newer notification for the same space or room replaces the older.

A tray icon (StatusNotifierItem) shows whether anything you follow is open, and
its menu lists each space and room with its state. While the stream is not
connected, states are shown as unknown. Without a tray host the service keeps
running and shows notifications only; `--no-tray` leaves the icon out on purpose.

It needs GLib/GIO 2.76 or later and a notification daemon (any desktop, or
mako, swaync, dunst). It does not load GTK.

### Configuration

Both files live in `$XDG_CONFIG_HOME/spacestate/` (default `~/.config/spacestate/`).
The service reloads when they change.

- `spaces`: the saved spaces of [SpaceStateCLI](https://github.com/kerker00/SpaceStateCLI),
  one endpoint per line with an optional `# name`. Add spaces with `spacestate add <name>`
  or edit the file by hand.
- `desktop.json` (optional): Mainframe rooms and the server.

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
cp .build/release/spacestate-desktop ~/.local/bin/
```

Until SpaceStateKit 0.4.0 is released, build against a checkout:
`SPACESTATEKIT_PATH=../SpaceStateKit swift build`.

Tray hosts find the icons by name, so install them into the icon theme:

```sh
mkdir -p ~/.local/share/icons/hicolor/scalable/status
cp data/icons/hicolor/scalable/status/*.svg ~/.local/share/icons/hicolor/scalable/status/
```

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
