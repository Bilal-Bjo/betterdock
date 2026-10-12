# BetterDock

A lightweight replacement for the macOS Dock, with iPhone-style app folders.

Apps that live in a folder never take up a spot in the Dock, even while they run. Native Swift and SwiftUI, no dependencies, around 20 MB of memory and no CPU use at rest.

## Features

- **Folders.** Click a folder and it springs open above its tile. Hover for half a second to peek.
- **A clean Dock.** Apps in folders, and apps you hide, never get their own icon.
- **Agent status.** A dot in the corner of an icon shows when a Claude Code or Codex agent running in that app is working (amber), finished (green) or waiting for you (red).
- **Unread badges** that wiggle when the count goes up.
- **Drag and drop.** Reorder icons, drop an app onto a folder to add it, or drag it up and away to remove it.
- **Right-click menus.** Open, hide, quit, new folder, rename folder, remove from folder, theme.
- **Magnification, auto-hide and launch bounce,** with spring-based motion that respects Reduce Motion.
- **Themes.** Glass, Wallpaper (tinted to your wallpaper) and Ember.

Apple's Dock keeps running in the background, so Cmd-Tab, Mission Control and app badges still work. It just never appears.

## Requirements

- macOS 14 or later on Apple silicon
- Xcode Command Line Tools (`xcode-select --install`)

## Install

```bash
git clone https://github.com/Bilal-Bjo/betterdock.git
cd betterdock
./install.sh --try   # build and run once; nothing is installed
./install.sh         # install, start at login, hide Apple's Dock
```

To remove it and bring Apple's Dock back:

```bash
./uninstall.sh
```

Unread badges are read from Apple's Dock, so BetterDock asks for Accessibility access the first time it starts.

## Configure

The first run copies `examples/` into `config/`. Edit `config/dock.json` for the Dock and `config/folders/<name>.json` for each folder, then run `./install.sh` again. Reordering, folder edits and the theme are saved back to these files.

```json
{
  "iconSize": 52,
  "magnifiedSize": 84,
  "autohide": true,
  "badges": true,
  "theme": "glass",
  "hidden": ["/Applications/Some Background App.app"],
  "items": [
    { "app": "/System/Library/CoreServices/Finder.app" },
    { "folder": "dev" }
  ]
}
```

```json
{
  "name": "Dev",
  "columns": 4,
  "apps": ["/Applications/Xcode.app", "/System/Applications/Utilities/Terminal.app"],
  "labels": { "/Applications/Xcode.app": "Xcode" }
}
```

## Agent status dots

```bash
./hooks/install-hooks.sh
```

This adds hooks to Claude Code (`~/.claude/settings.json`) and Codex (`~/.codex/hooks.json`) and keeps the ones you already have. Each hook records the agent's state; BetterDock puts the dot on the app the agent runs in, such as Claude, Terminal or your editor. Codex asks you to trust the new hooks the next time it starts.

## How it works

BetterDock is an accessory app that draws a borderless panel at the Dock's window level. It tracks the cursor with event monitors to reveal, magnify and hide, launches apps through `NSWorkspace`, and watches app launches and quits to decide which icons to show. Apple's Dock is kept hidden with a very long auto-hide delay.

```
Sources/
  Shared/Folder.swift   folder model, grid view, panel and motion
  Shared/Status.swift   themes, agent dots, badges
  DockApp/main.swift    the Dock: layout, magnification, drag and drop, menus
  DockApp/Live.swift    agent status watcher, badge reader, poof effect
hooks/                  Claude Code and Codex status hooks
examples/               starter configuration
```

## License

MIT
