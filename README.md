# PinTop

PinTop is a small macOS menu bar utility for keeping visual references above normal windows.

## Features

- Pin the current foreground window as an always-on-top snapshot.
- Drag to select a screen area and pin that screenshot until you close it.
- Customize global shortcuts from the menu bar.
- Close all pinned snapshots from the menu bar.

## macOS API note

macOS public APIs do not let one app force arbitrary windows from other apps to become truly always-on-top. PinTop uses the reliable public approach: capture the selected window or screen area, then display that image in a floating `NSPanel`.

## Permissions

PinTop needs Screen Recording permission to capture windows and screen selections. `script/build_and_run.sh` installs and launches the app from `~/Applications/PinTop.app`; grant permission to that installed app.

Use the menu item `Register Screen Recording Permission` once so macOS adds PinTop to the permission list, enable PinTop in System Settings, then quit and relaunch the app. If macOS does not add PinTop to the list automatically, use `Reveal PinTop App`, then add that `.app` manually with the `+` button in System Settings > Privacy & Security > Screen & System Audio Recording.

The local development bundle is ad-hoc signed as `local.codex.PinTop` when `script/build_and_run.sh` runs. If you rebuild after changing code, macOS may ask you to grant Screen Recording again because the executable hash changed.

## Build

```sh
swift build
```

## Run

```sh
./script/build_and_run.sh
```
