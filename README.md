# BetterDock

A lightweight replacement for the macOS Dock, with iPhone-style app folders.

Apps that live in a folder never take up a spot in the Dock, even while they run. Native Swift and SwiftUI, no dependencies, and no measurable CPU at rest: 0.0% hidden, about 0.1% on screen with widgets and a glowing agent dot.

## Features

- **Folders.** Click a folder and it springs open above its tile. Hover for half a second to peek. Give each folder its own colour from its right-click menu; it shakes when you drag an app over it.
- **A clean Dock.** Apps in folders, and apps you hide, never get their own icon.
- **Agent status.** A dot in the corner of an icon shows when a Claude Code or Codex agent running in that app is working (amber), finished (green) or waiting for you (red). If an agent needs you while the Dock is hidden, a soft sound plays and its tile pulses the next time the Dock shows.
- **Unread badges** that wiggle when the count goes up.
- **Drag and drop.** Reorder icons, drop an app onto a folder to add it, drag it back out of an open folder, drag a running app from the right side to keep it, or drag it up and away to remove it. Drop files on an app to open them with it.
- **Trash.** Full or empty at a glance, click to open, drop files to delete, right-click to empty.
- **Right-click menus.** Open, hide, quit, new folder, rename folder, remove from folder, plus a BetterDock menu for themes, icon styles, widgets and settings.
- **Magnification, auto-hide and launch bounce,** with spring-based motion that respects Reduce Motion.
- **Themes.** Glass (Liquid Glass), Graphite (dark smoked glass), Paper (warm and light, for light wallpapers), Midnight (deep navy with a blue rim light) and Wallpaper (tinted with your wallpaper's dominant colour). Each one styles the bar, folders, labels, separators and widgets together.
- **Profiles.** Named layouts such as Work, Personal and Focus, switched from the menu or automatically by time of day or Wi-Fi network.
- **Multiple displays.** The Dock follows you to whichever display you push the cursor to the bottom of, like Apple's.
- **Icon styles.** Default, Dark, Clear and Tinted, using the same icon variants macOS draws for each app, with seven tint colours.
- **Widgets.** Now Playing, Calendar, Weather, Clock, Focus Timer, System, Network, Storage, Battery and Agents. Each one is Small, Medium or Large from its right-click menu.
- **Personal.** Icon size, magnification, auto-hide, theme, icon style and tint are all one right-click away.

Apple's Dock keeps running in the background, so Cmd-Tab, Mission Control and app badges still work. It just never appears.

## Requirements

- macOS 14 or later on Apple silicon
- Xcode Command Line Tools (`xcode-select --install`)

## Install

Download BetterDock, drag it to Applications and open it. A short setup offers to hide Apple's Dock, lets you pick a theme, suggests folders for the apps on your Mac and explains the optional permissions. Open it again any time from **BetterDock ▸ Setup…**. Settings live in `~/Library/Application Support/BetterDock/`, and **Open at Login** is a menu toggle.

From source:

```bash
git clone https://github.com/Bilal-Bjo/betterdock.git
cd betterdock
./install.sh --try   # build and run once; nothing is installed, Apple's Dock stays
./install.sh         # developer install: ~/Applications, a LaunchAgent, settings in config/
./install.sh --dist  # standalone build/BetterDock.app to sign, notarize and ship
```

### What happens to Apple's Dock

**Hide Apple's Dock** (in setup and in the BetterDock menu) hides it for good: it sets a very long auto-hide delay, so pushing the cursor to the edge never reveals it, and makes it as small as possible for the one place macOS still forces it on screen, Mission Control. Apple's Dock keeps running in the background, which is what keeps Cmd-Tab, Mission Control and app badges working. Your original Dock settings are saved to `apple-dock-backup.plist` in the settings folder first. Turning the option off restores them exactly, and quitting BetterDock offers to do the same.

If you want to do it by hand instead:

```bash
defaults write com.apple.dock autohide -bool true
defaults write com.apple.dock autohide-delay -float 1000
killall Dock
```

To remove a developer install and bring Apple's Dock back exactly as it was:

```bash
./uninstall.sh
```

Unread badges are read from Apple's Dock, so BetterDock asks for Accessibility access during setup. The Now Playing widget asks once for permission to talk to Spotify or Music, and the Calendar widget asks for calendar access. Weather comes from Open-Meteo for the city in your Mac's time zone; nothing else leaves your Mac.

To check what each widget reads on your Mac:

```bash
/Applications/BetterDock.app/Contents/MacOS/BetterDock --widget-test
```

## Configure

Most settings live in the right-click menu. Right-click any icon and open **BetterDock** for Profile, Theme, Icon Style, Icon Tint, Icon Size, Magnification, Hide Automatically, Widgets, Agent Sounds, Hide Apple's Dock, Open at Login, Setup…, **Edit Settings…** and **Show Settings in Finder**. Right-click a widget to resize it. Folders are managed from their own menus: new folder, rename, colour, remove from folder.

Everything is stored as JSON in `~/Library/Application Support/BetterDock/` (or `config/` for a developer install), copied from `examples/` on first launch: `dock.json` for the Dock and `folders/<name>.json` for each folder. Save `dock.json` in any editor and the Dock reloads with the change. Reordering, folder edits, theme and widget choices are written back to the same files.

```json
{
  "iconSize": 52,
  "magnifiedSize": 84,
  "autohide": true,
  "badges": true,
  "theme": "glass",
  "iconStyle": "default",
  "agentSound": "attention",
  "hidden": ["/Applications/Some Background App.app"],
  "items": [
    { "app": "/System/Library/CoreServices/Finder.app" },
    { "folder": "dev" },
    { "widget": "nowPlaying" }
  ]
}
```

| Key | Values |
| --- | --- |
| `theme` | `glass`, `graphite`, `paper`, `midnight`, `wallpaper` (the old `ember` opens as `graphite`) |
| `iconStyle` | `default`, `dark`, `clear`, `tinted` |
| `iconTint` | `wallpaper`, `yellow`, `blue`, `pink`, `green`, `purple`, `graphite` |
| `agentSound` | `attention` (default), `all` (also when an agent finishes), `off` |
| `items` | the current layout: `app`, `folder` or `widget` (with `size`: `small`, `medium`, `large`) |
| `profile`, `profiles` | the current profile, and every profile's saved `items` |
| `profileRules`, `autoProfile` | rules for switching profiles on their own, and whether they run (default `true`) |
| `onboarded` | `true` once setup has been shown |

```json
{
  "name": "Dev",
  "columns": 4,
  "color": "blue",
  "apps": ["/Applications/Xcode.app", "/System/Applications/Utilities/Terminal.app"],
  "labels": { "/Applications/Xcode.app": "Xcode" }
}
```

A folder's `color` is `graphite` (when left out), `red`, `orange`, `yellow`, `green`, `blue` or `purple`.

### Profiles

**BetterDock ▸ Profile ▸ New Profile…** saves the current layout under a name; after that, every profile keeps its own icons, folders and widgets, and switching swaps them in place. Rules switch profiles for you. They are checked once a minute and when the Mac wakes, and the first rule that matches wins; a profile you pick by hand stays until a different rule starts to apply.

```json
"profileRules": [
  { "profile": "Work", "days": ["weekdays"], "from": "09:00", "to": "18:00" },
  { "profile": "Work", "wifi": "Office" },
  { "profile": "Focus", "days": ["sat", "sun"] }
]
```

`days` takes `mon` to `sun`, `weekdays` and `weekends`; a time window may cross midnight. Wi-Fi rules need the network name, which recent versions of macOS only share with apps allowed to use Location; when BetterDock can read it, the Profile menu offers **Use “Work” on “Office”** to add the rule for you.

## Agent status dots

```bash
./hooks/install-hooks.sh
```

This adds hooks to Claude Code (`~/.claude/settings.json`) and Codex (`~/.codex/hooks.json`) and keeps the ones you already have. Each hook records the agent's state; BetterDock puts the dot on the app the agent runs in, such as Claude, Terminal or your editor. Codex asks you to trust the new hooks the next time it starts.

## How it works

BetterDock is an accessory app that draws a borderless panel at the Dock's window level on the display you last pushed the cursor to the bottom of. It tracks the cursor with event monitors to reveal, magnify and hide, launches apps through `NSWorkspace`, and watches app launches and quits to decide which icons to show. Apple's Dock is kept hidden with a very long auto-hide delay, and BetterDock registers itself to open at login with `SMAppService`.

```
Sources/
  Shared/Folder.swift   folder model, grid view, panel and motion
  Shared/Theme.swift    the five themes and the wallpaper's dominant colour
  Shared/Status.swift   agent dots, pulses, badges
  Shared/IconStyle.swift  dark, clear and tinted icons
  Shared/SystemIcons.swift  the icon variants macOS renders (IconServices)
  DockApp/main.swift    the Dock: layout, magnification, drag and drop, menus
  DockApp/Live.swift    agent status watcher, badge reader, poof effect
  DockApp/Widgets.swift ten widgets and their data sources
  DockApp/Setup.swift   settings folder, login item, hiding and restoring Apple's Dock
  DockApp/Onboarding.swift  first-run setup window
  DockApp/Profiles.swift    profiles and their switching rules
hooks/                  Claude Code and Codex status hooks
examples/               starter configuration
```

## License

MIT
