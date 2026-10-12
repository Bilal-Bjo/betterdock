# BetterDock

A lightweight replacement for the macOS Dock, with iPhone-style app folders.

Apps that live in a folder never take up a spot in the Dock, even while they run. Native Swift and SwiftUI, no dependencies, and no measurable CPU at rest: 0.0% hidden, about 0.1% on screen with widgets and a glowing agent dot.

## Features

- **Folders.** Click a folder and it springs open above its tile. Hover for half a second to peek.
- **A clean Dock.** Apps in folders, and apps you hide, never get their own icon.
- **Agent status.** A dot in the corner of an icon shows when a Claude Code or Codex agent running in that app is working (amber), finished (green) or waiting for you (red).
- **Unread badges** that wiggle when the count goes up.
- **Drag and drop.** Reorder icons, drop an app onto a folder to add it, drag it back out of an open folder, drag a running app from the right side to keep it, or drag it up and away to remove it. Drop files on an app to open them with it.
- **Trash.** Full or empty at a glance, click to open, drop files to delete, right-click to empty.
- **Right-click menus.** Open, hide, quit, new folder, rename folder, remove from folder, plus a BetterDock menu for themes, icon styles, widgets and settings.
- **Magnification, auto-hide and launch bounce,** with spring-based motion that respects Reduce Motion.
- **Themes.** Glass, Wallpaper (tinted to your wallpaper) and Ember, switchable from any right-click menu.
- **Icon styles.** Default, Dark, Clear and Tinted, using the same icon variants macOS draws for each app, with seven tint colours.
- **Widgets.** Now Playing, Calendar, Weather, Clock, Focus Timer, System, Network, Storage, Battery and Agents. Each one is Small, Medium or Large from its right-click menu.
- **Personal.** Icon size, magnification, auto-hide, theme, icon style and tint are all one right-click away.

Apple's Dock keeps running in the background, so Cmd-Tab, Mission Control and app badges still work. It just never appears.

## Requirements

- macOS 14 or later on Apple silicon
- Xcode Command Line Tools (`xcode-select --install`)

## Install

```bash
git clone https://github.com/Bilal-Bjo/betterdock.git
cd betterdock
./install.sh --try   # build and run once; nothing is installed, Apple's Dock stays
./install.sh         # install, start at login, hide Apple's Dock
```

### What happens to Apple's Dock

`./install.sh` hides Apple's Dock for good: it sets a very long auto-hide delay, so pushing the cursor to the edge never reveals it, and makes it as small as possible for the one place macOS still forces it on screen, Mission Control. Apple's Dock keeps running in the background, which is what keeps Cmd-Tab, Mission Control and app badges working. Your original Dock settings are saved to `config/apple-dock-backup.plist` first.

If you want to do it by hand instead:

```bash
defaults write com.apple.dock autohide -bool true
defaults write com.apple.dock autohide-delay -float 1000
killall Dock
```

To remove BetterDock and bring Apple's Dock back exactly as it was:

```bash
./uninstall.sh
```

Unread badges are read from Apple's Dock, so BetterDock asks for Accessibility access the first time it starts. The Now Playing widget asks once for permission to talk to Spotify or Music, and the Calendar widget asks for calendar access. Weather comes from Open-Meteo for the city in your Mac's time zone; nothing else leaves your Mac.

To check what each widget reads on your Mac:

```bash
~/Applications/BetterDock.app/Contents/MacOS/BetterDock --widget-test
```

## Configure

Most settings live in the right-click menu. Right-click any icon and open **BetterDock** for Theme, Icon Style, Icon Tint, Icon Size, Magnification, Hide Automatically, Widgets, **Edit Settings…** and **Show Settings in Finder**. Right-click a widget to resize it. Folders are managed from their own menus: new folder, rename, remove from folder.

Everything is stored as JSON in `config/` (the first run copies it from `examples/`): `config/dock.json` for the Dock and `config/folders/<name>.json` for each folder. Save `dock.json` in any editor and the Dock reloads with the change. Reordering, folder edits, theme and widget choices are written back to the same files.

```json
{
  "iconSize": 52,
  "magnifiedSize": 84,
  "autohide": true,
  "badges": true,
  "theme": "glass",
  "iconStyle": "default",
  "hidden": ["/Applications/Some Background App.app"],
  "items": [
    { "app": "/System/Library/CoreServices/Finder.app" },
    { "folder": "dev" },
    { "widget": "nowPlaying" }
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
  Shared/IconStyle.swift  dark, clear and tinted icons
  Shared/SystemIcons.swift  the icon variants macOS renders (IconServices)
  DockApp/main.swift    the Dock: layout, magnification, drag and drop, menus
  DockApp/Live.swift    agent status watcher, badge reader, poof effect
  DockApp/Widgets.swift ten widgets and their data sources
hooks/                  Claude Code and Codex status hooks
examples/               starter configuration
```

## License

MIT
