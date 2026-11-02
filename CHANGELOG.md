# Changelog

## Unreleased

- While the change stream stays unavailable, for example at the server's connection
  limit, read the states every few minutes, so notifications continue with a delay.
- A saved space outside SpacePush's directory no longer stops all notifications. The
  server refuses the whole stream then, so the states are read every five minutes.
- The tray icon shows right after installing, without restarting the Omarchy shell or
  logging in again.
- A lost log no longer ends the service, for example after the terminal it started from
  closed.
- The settings window lists all spaces before you type, yours first, and also finds them
  by place. The Mainframe rooms appear once Mainframe is chosen.
- With Mainframe chosen, the tray menu shows all its rooms under it. The rooms tab now
  chooses only which of them notify. Rooms count only while Mainframe is chosen, and their
  choice is back when it is chosen again. Rooms not chosen make way when SpacePush's limit
  of 50 topics would be reached.
- With more chosen spaces and rooms than that limit, the settings window says that
  notifications come late, as the service reads the states instead.
- The settings window shows whether the background service runs, and can start it.
- The settings window follows changes by other programs, such as `spacestate add`.
- A failed load no longer shows "Loading…" for good.
- Add `--version` to both programs.
- Do not log reads that a configuration reload cancels.
- Add a German translation, an application icon and an AUR package definition.
- Use the same state texts as the SpaceState apps: "Keyholders only" and "Members only".

## 0.1.0 — 2026-11-02

First version, as source only. It is tested on Hyprland with the Omarchy shell; other
desktops should work through the same D-Bus standards but have not been checked.

- `spacestate-desktop`: a background service that shows a notification when a followed
  space or Mainframe room opens or closes, and reads the current states after every
  connection, so a change missed while offline is shown once.
- A tray icon (StatusNotifierItem) that shows whether anything followed is open, with
  a menu listing each space and room. Without a tray host the service keeps running.
- `spacestate-settings`: a GTK 4 window to search the SpacePush directory, choose spaces
  and Mainframe rooms, and set autostart and the servers.
- Reads and writes SpaceStateCLI's `spaces` file; rooms and settings are in `desktop.json`.

Not included yet: packages, translations, and an application icon.
