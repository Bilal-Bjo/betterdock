<div align="center">

<img src="docs/logo.svg" width="112" alt="BetterDock">

# BetterDock

**The macOS Dock, finally organised.**

iPhone-style folders, live status for your AI agents, widgets and themes.<br>
Apps in a folder never clutter your Dock again, even while they run.

[![MIT License](https://img.shields.io/badge/license-MIT-f3d94e?style=flat-square&labelColor=0b0c0d)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-f3d94e?style=flat-square&labelColor=0b0c0d&logo=apple&logoColor=white)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-native-f3d94e?style=flat-square&labelColor=0b0c0d&logo=swift&logoColor=white)](Sources)
[![CPU at rest](https://img.shields.io/badge/CPU%20at%20rest-0%25-f3d94e?style=flat-square&labelColor=0b0c0d)](#performance)

[**Website**](https://betterdock.vercel.app) · [**Watch the film**](https://betterdock.vercel.app) · [**Install**](#install)

<br>

<a href="https://betterdock.vercel.app"><img src="docs/hero.jpg" alt="A BetterDock folder springing open above the Dock" width="100%"></a>

</div>

<br>

## Why

The Dock fills up. Every app you run takes a spot, and there is no way to group the ones you keep together. BetterDock gives the Dock folders, and apps inside a folder stay inside it, running or not. Apple's Dock keeps working in the background, so Cmd-Tab, Mission Control and app badges behave exactly as before. It just never appears.

## Features

<table>
<tr>
<td width="50%" valign="top">

### 📁 Folders
A folder springs open above its tile. Hover for half a second to peek. Right-click any app for **New Folder**, drag apps in and back out, rename it, give it a colour.

</td>
<td width="50%" valign="top">

### 🟠 Agent status
A dot on the app your Claude Code or Codex agent runs in: **amber** while it works, **green** when it's done, **red** when it needs you. A sound when one finishes or needs you while the Dock is hidden: pick one of macOS's or drop in your own.

</td>
</tr>
<tr>
<td valign="top">

### 📊 Widgets
Now Playing, **AI Usage** (weekly Claude and Codex limits), Calendar, Weather, Clock, Focus Timer, System, Network, Storage, Battery and Agents. Each one Small, Medium or Large.

</td>
<td valign="top">

### 🎨 Make it yours
Five themes (Glass, Graphite, Paper, Midnight and Wallpaper, tinted to your desktop) and Default, Dark, Clear and Tinted icon styles drawn from the variants macOS designs for each app.

</td>
</tr>
<tr>
<td valign="top">

### ✋ Drag and drop
Reorder with a drag, drop an app on a folder to file it, drag a running app in to keep it, pull one up and away to remove it. Drop files on an app to open them with it.

</td>
<td valign="top">

### 🗑️ A real Trash
Full or empty at a glance. Click to open, drop files to delete, right-click to empty.

</td>
</tr>
<tr>
<td valign="top">

### 🔀 Profiles
Work, Personal and Focus layouts, each with its own icons, folders and widgets. Switch from the menu, or let them switch by time of day or Wi-Fi network.

</td>
<td valign="top">

### 🖥️ Every display
The Dock follows you to whichever screen you push the cursor to the bottom of, like Apple's. A short setup on first launch gets you going.

</td>
</tr>
</table>

<div align="center">
<img src="docs/agents.jpg" alt="Agent status dots on Dock icons" width="100%">
</div>

## Performance

BetterDock uses native Swift and SwiftUI. Core builds have no third-party dependencies; release builds bundle Sparkle for updates. Widget data polling stops while the Dock is hidden. Badge checks slow down, and minute-scale recovery/profile/agent housekeeping continues in the background. Looping agent-dot animations use Core Animation.

The `--bench` diagnostic reports frame timing on the Mac running it. Static fitting/overflow geometry is cached until a layout, size, display or drag-removal change; drawing and hit testing share a single cursor layout. In the fixed 24-app + Storage-widget Mini benchmark, this reduced median frame time from 11.48 ms to 2.17 ms and p95 from 12.07 ms to 2.73 ms. `Tests/benchmark-mini.sh` enforces an 8.3 ms p95 frame budget for that fixture. CPU usage varies with the layout, widgets, agent updates and hardware; a hidden Dock is designed to do very little work, not literally no work.

## Requirements

- macOS 14 or later on Apple silicon
- Xcode Command Line Tools: `xcode-select --install`

## Install

**The easy way:** ask your coding agent (Claude Code, Codex, Cursor…):

> Install BetterDock by following https://github.com/Bilal-Bjo/betterdock/blob/main/INSTALL.md

**By hand:**

```bash
git clone https://github.com/Bilal-Bjo/betterdock.git
cd betterdock
./install.sh --try   # build and run once: nothing is installed, Apple's Dock stays
./install.sh         # install, start at login, hide Apple's Dock
```

To remove BetterDock and bring Apple's Dock back exactly as it was:

```bash
./uninstall.sh
```

<details>
<summary><b>What happens to Apple's Dock</b></summary>

<br>

`./install.sh` hides Apple's Dock for good: it sets a very long auto-hide delay, so pushing the cursor to the edge never reveals it, and makes it as small as possible for the one place macOS still forces it on screen, Mission Control. Apple's Dock keeps running in the background, which keeps Cmd-Tab, Mission Control and app badges working. Your original Dock settings are saved to `config/apple-dock-backup.plist` first.

To do it by hand instead:

```bash
defaults write com.apple.dock autohide -bool true
defaults write com.apple.dock autohide-delay -float 1000
killall Dock
```

</details>

<details>
<summary><b>Permissions and privacy</b></summary>

<br>

Every permission is optional.

- **Accessibility:** reads unread badges from Apple's Dock.
- **Automation:** Spotify or Music for the Now Playing widget, Finder for the Trash.
- **Calendar:** your next event in the Calendar widget.

There is no account and no analytics. The only network requests are album art for Now Playing and the weather from Open-Meteo for the city in your Mac's time zone.

To check what each widget reads on your Mac:

```bash
~/Applications/BetterDock.app/Contents/MacOS/BetterDock --widget-test
```

</details>

## Agent status and AI usage

```bash
./hooks/install-hooks.sh
```

This adds hooks to Claude Code (`~/.claude/settings.json`) and Codex (`~/.codex/hooks.json`) and keeps the ones you already have. Each hook records an agent's state, and BetterDock puts the dot on the app the agent runs in: Claude, Terminal, your editor. Codex asks you to trust the new hooks the next time it starts.

The **AI Usage** widget shows this week's limits. Codex usage is read from its local session logs. Claude usage comes from the `rate_limits` Claude Code passes to its status line, which the installer sets up if you don't have a status line yet (Pro and Max plans).

## Configure

Open **Settings…** from the BetterDock menu-bar icon, right-click an icon → **BetterDock**, or press **Cmd+,** while BetterDock is focused. The settings window provides appearance, widgets, weather city, profiles, and settings export/import.

**Control–Option–Space** reveals and focuses the Dock. Use Left/Right and Return to open an item; Escape dismisses keyboard mode. Folders have search and arrow/Return navigation. Large layouts shrink to fit, with remaining items reachable through **More apps**; folder contents scroll.

Right-click a widget to resize it, a folder to rename or colour it. Other advanced controls remain in the BetterDock context menu.

Settings are validated before application, written atomically, and backed up alongside `dock.json`. An invalid external edit is archived and the last working configuration is restored while the Dock stays running. `dock.json.previous` keeps the prior saved generation; `dock.json.last-good` is used for recovery. Unavailable apps retain their pins.

Profiles own independent folder copies. Existing shared folders are separated on migration; deleting a folder cannot delete another profile's folder. A focus timer finishes even with the Dock hidden and shows a local completion banner. Agent sessions without updates for 30 minutes show a gray stale indicator, then expire after 12 hours.

If the app cannot start and Apple's Dock remains hidden, run:

```bash
~/Applications/BetterDock.app/Contents/MacOS/BetterDock --restore-apple-dock
```

Restoration checks the import result and keeps the original backup on failure. Preview mode never changes Apple Dock or login preferences.

Everything is plain JSON in `~/Library/Application Support/BetterDock/` (`config/` in the repo for a developer install), copied from `examples/` on first launch. Save `dock.json` in any editor and the Dock reloads.

<details>
<summary><b>Settings reference</b></summary>

<br>

`dock.json`

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
    { "widget": "nowPlaying", "size": "medium" }
  ]
}
```

| Key | Values |
| --- | --- |
| `theme` | `glass`, `graphite`, `paper`, `midnight`, `wallpaper` |
| `iconStyle` | `default`, `dark`, `clear`, `tinted` |
| `iconTint` | `wallpaper`, `yellow`, `blue`, `pink`, `green`, `purple`, `graphite` |
| `agentSound` | `attention` (default), `all`, `off` |
| `agentSounds` | the sound for `done` and `attention`: a macOS sound (`Hero`), a file in the `sounds/` folder (`done.mp3`), or `none` |
| `items` | the layout: `app`, `folder` or `widget` (with `size`: `small`, `medium`, `large`) |
| `profile`, `profiles` | the current profile, and each profile's saved `items` |
| `profileRules`, `autoProfile` | rules that switch profiles on their own, and whether they run |
| `onboarded` | `true` once setup has been shown |

`folders/dev.json`

```json
{
  "name": "Dev",
  "columns": 4,
  "color": "blue",
  "apps": ["/Applications/Xcode.app", "/System/Applications/Utilities/Terminal.app"],
  "labels": { "/Applications/Xcode.app": "Xcode" }
}
```

A folder's `color` is `graphite` (the default), `red`, `orange`, `yellow`, `green`, `blue` or `purple`.

</details>

<details>
<summary><b>Profiles and switching rules</b></summary>

<br>

**BetterDock ▸ Profile ▸ New Profile…** saves the current layout under a name; from then on each profile keeps its own icons, folders and widgets, and switching swaps them in place. Rules are checked once a minute and when the Mac wakes; the first match wins, and a profile you pick by hand stays until a different rule starts to apply.

```json
"profileRules": [
  { "profile": "Work", "days": ["weekdays"], "from": "09:00", "to": "18:00" },
  { "profile": "Work", "wifi": "Office" },
  { "profile": "Focus", "days": ["sat", "sun"] }
]
```

`days` takes `mon` to `sun`, `weekdays` and `weekends`; a time window may cross midnight. Wi-Fi rules need the network name, which recent macOS versions only share with apps allowed to use Location.

</details>

## How it works

BetterDock is an accessory app that draws a borderless panel at the Dock's window level, on the display you last pushed the cursor to the bottom of. It tracks the cursor with event monitors to reveal, magnify and hide, launches apps through `NSWorkspace`, watches launches and quits to decide which icons to show, and opens at login through `SMAppService`.

```
Sources/
  Shared/Folder.swift          folder model, grid view, panel and motion
  Shared/Theme.swift           the five themes and the wallpaper's dominant colour
  Shared/Status.swift          agent dots, pulses, badges
  Shared/IconStyle.swift       dark, clear and tinted icons
  Shared/SystemIcons.swift     the icon variants macOS renders (IconServices)
  DockApp/Configuration.swift  typed configuration schema
  DockApp/ConfigStore.swift    validation, atomic saves, recovery and folder isolation
  DockApp/DockModel.swift      tile identity, fitting, overflow and layout
  DockApp/DockViews.swift      Dock presentation and accessible tile actions
  DockApp/Controls.swift       settings, keyboard controls and menu-bar recovery
  DockApp/main.swift           lifecycle, drag and drop and action coordination
  DockApp/Live.swift           agent status, unread badges, poof effect
  DockApp/Widgets.swift        widget presentation
  DockApp/WidgetData.swift     widget data sources and focus timer completion
  DockApp/Setup.swift          settings folder, login item, hiding and restoring Apple's Dock
  DockApp/Onboarding.swift     first-run setup
  DockApp/Profiles.swift       profiles and their switching rules
  DockApp/Updater.swift        Sparkle updates for release builds
hooks/                         Claude Code and Codex hooks, status line
examples/                      starter configuration
release/, packaging/           signed release builds (see RELEASING.md)
```

Icon styles use IconServices, a private macOS framework, to draw the dark and monochrome icons Apple designs for each app. If a macOS update changes it, BetterDock falls back to its own renderer.

## Verification

```bash
Tests/run-mini.sh
Tests/benchmark-mini.sh  # cursor-sweep performance check on the Mini
```

This syncs sources to the Mac mini, compiles on its external SSD, and runs native regression and integration checks in an isolated GUI session. It never changes the real Dock configuration. GUI fixtures and the small executable stage temporarily under `/tmp` because the Mini's GUI launchd session cannot access removable storage; staging is removed afterwards.

For this developer setup, `BETTERDOCK_BUILD_HOST=mini ./install.sh` also routes compilation and signing to the Mini. Without that variable, manual source installations build on the current Mac. Bilal's agents must use the Mini path (see `AGENTS.md`).

GitHub Actions checks scripts and example JSON on pushes/PRs. Native CI is manually dispatched on a self-hosted runner labeled `betterdock-mini`; that runner must be registered separately. Native method-level integration checks complement a real GUI walkthrough; neither proves long-term stability or every monitor/permission combination.

Release builds record a source-content digest. Publishing refuses artifacts built from different sources.

## License

[MIT](LICENSE). Not affiliated with Apple.
