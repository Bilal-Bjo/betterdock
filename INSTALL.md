# Installing BetterDock with an AI agent

Tell your coding agent (Claude Code, Codex, Cursor, …):

> Install BetterDock by following https://github.com/Bilal-Bjo/betterdock/blob/main/INSTALL.md

The rest of this page is written for the agent.

---

## For the agent

You are installing BetterDock, an open-source replacement for the macOS Dock, on the user's Mac. It is built from source; there is no download. Work through the steps in order, run the commands yourself, and keep the user informed in one short line per step. Ask the user before any step marked **ask first**: those change their system and they should decide.

### 1. Check the Mac

```bash
sw_vers -productVersion   # must be 14.0 or later
uname -m                  # must be arm64 (Apple silicon)
xcode-select -p           # must print a path
```

- If macOS is older than 14 or the Mac is Intel, stop and tell the user BetterDock doesn't support it yet.
- If `xcode-select -p` fails, run `xcode-select --install`, tell the user to click **Install** in the dialog that appears, and wait until `xcode-select -p` succeeds.

### 2. Get the code

```bash
git clone https://github.com/Bilal-Bjo/betterdock.git ~/betterdock
cd ~/betterdock
```

If `~/betterdock` already exists, `cd` into it and run `git pull` instead. The configuration lives inside this folder (`config/`), so tell the user to keep it where it is.

### 3. Try it first

```bash
./install.sh --try
```

This builds BetterDock (about a minute) and runs it once. Nothing is installed and Apple's Dock is not touched. Tell the user to push their cursor to the bottom edge of the screen to see BetterDock, and ask whether they want to keep it.

If the build fails, show the user the first error line and check step 1 again.

### 4. Install it (ask first)

Explain in one sentence, then ask:

> Installing starts BetterDock at login and hides Apple's Dock (it keeps running in the background, so Cmd-Tab and Mission Control still work). Your current Dock settings are backed up and `./uninstall.sh` puts them back. Install?

If they agree:

```bash
./install.sh
```

Confirm it worked:

```bash
launchctl print "gui/$(id -u)/com.betterdock.app" | grep -m1 "state"   # state = running
pgrep -x BetterDock | wc -l                                               # 1
```

### 5. Agent status dots and AI usage (optional, ask first)

BetterDock can show a dot on the app a Claude Code or Codex agent runs in (amber working, green done, red needs you), and a widget with weekly Claude and Codex usage. This adds hooks to `~/.claude/settings.json` and `~/.codex/hooks.json`, keeps existing hooks, writes a backup next to each file, and adds a Claude Code status line only if the user has none. Ask before running:

```bash
./hooks/install-hooks.sh
```

Tell the user that Codex will ask them to trust the new hooks the next time it starts.

### 6. Permissions

All optional. macOS asks the user directly; you can't click these for them. Tell them what each one is for when it appears:

- **Accessibility:** unread badges (WhatsApp, Mail…).
- **Automation:** Spotify or Music for Now Playing, Finder for the Trash.
- **Calendar:** the next event in the Calendar widget.

### 7. Show the user around

Tell them, briefly:

- Right-click any icon → **BetterDock** for themes, icon styles, widgets, icon size, magnification and auto-hide.
- Right-click an app → **New Folder with …**. Drag apps onto a folder to add them, and out of an open folder to remove them.
- Drag a running app from the right of the separator into the Dock to keep it.
- Settings are plain JSON in `~/betterdock/config/dock.json`; saving it reloads the Dock.

### Updating

```bash
cd ~/betterdock && git pull && ./install.sh
```

### Uninstalling

```bash
cd ~/betterdock && ./uninstall.sh
```

This stops BetterDock, removes the login item and restores Apple's Dock exactly as it was.

### Rules

- Don't use `sudo`; nothing here needs it.
- Don't edit `com.apple.dock` settings yourself; `install.sh` and `uninstall.sh` do it with a backup.
- Don't move or delete `~/betterdock` after installing; the installed app reads its configuration from there.
- If anything fails twice the same way, stop and show the user the exact error instead of retrying.
