![macOS](https://img.shields.io/badge/platform-macOS%2026-blue)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](../LICENSE)

# MyAgents for macOS

A menu-bar-only ("agent") app that watches **all your Claude Code and Codex coding-agent sessions
at once**: what each one is doing (thinking / running a tool / awaiting permission / idle),
**click to jump to its terminal**, and your Claude/Codex usage — **without reading any token or
calling any undocumented endpoint**.

This is the macOS port of the mature, in-production [Windows app](../README.md) (`src/MyAgents/`).
Same product, same privacy contract, native menu-bar/popover UI on macOS instead of a corner
widget on Windows. See [`../CONTEXT.md`](../CONTEXT.md) (local-only, not shipped) for the full
port history if you're working on this codebase; this README is for people running the app.

## What you get

- **A row per live session** in the popover: name, folder, and state (thinking / tool / awaiting
  permission / idle), color-accented by provider (Claude orange / Codex teal).
- **Click-to-focus.** Click a row and the exact terminal tab/window for that session comes to the
  front (exact tab in Terminal.app/iTerm2/Ghostty; the app's window in Warp/VS Code/Cursor).
- **A status-bar glyph** that animates with activity and can show a usage-percent badge.
- **Usage bars** (opt-in) for Claude's 5h/7d windows and Codex's 5h/7d windows.
- **A notification** the moment a session needs your permission.
- **Self-installing hook scripts** — the app installs/repairs/removes its own tiny Node hook
  scripts; you never run an install script by hand.

## Who this is for

macOS users who already have **Claude Code** and/or **Codex** installed and signed in, run
several sessions at once, and want one place to see what each is doing and jump to it.

## Requirements

- **macOS 26 (Tahoe)** or later, Apple Silicon or Intel.
- [Claude Code](https://claude.com/claude-code) and/or [Codex](https://developers.openai.com/codex)
  installed and authenticated.
- **Node.js** available on your `PATH` — the status hooks are tiny Node scripts, and the app
  launches Codex's `app-server` through a login shell to pick up the same `PATH` your terminal has.

## Install

**Homebrew (recommended):**

```bash
brew install --cask miguelangelxramirez/tap/myagents
```

(See `dist/Casks/myagents.rb` in this repo for the cask source; it lives in a separate personal
tap, `miguelangelxramirez/homebrew-tap`, per Homebrew's rules for third-party casks.)

**Or download the notarized zip directly** from the
[Releases](https://github.com/miguelangelxramirez/MyAgents/releases) page, unzip, and drag
`MyAgentsMac.app` to `/Applications`.

Either way, the app is **Developer ID signed and notarized** — Gatekeeper will let it run with no
"unidentified developer" warning (see [PUBLISHING.md](../PUBLISHING.md) for how releases are built).

## Use

Launch it (Spotlight/Launchpad → "MyAgents", or `open -a MyAgents`). It's a **menu-bar-only app**
— no Dock icon, no window; everything lives behind the glyph in the menu bar.

- Click the glyph to open the popover.
- **⚙ menu** (gear icon inside the popover): **Enable tracking** (first run — installs the
  hooks), **Repair tracking** / **Remove tracking** (once installed), **Show usage** toggle,
  **Open at login** toggle, **About MyAgents** (version + build date), **Quit MyAgents**.
- Usage is **opt-in** — enable **Show usage** to see the 5h/7d bars.

### Permissions it will ask you for

MyAgents asks for exactly two macOS permissions, both the first time it actually needs them
(never upfront):

- **Automation** (System Settings → Privacy & Security → Automation → MyAgents → your terminal
  app), the first time you click a session row — it uses this to tell Terminal.app/iTerm2/Ghostty/
  Warp/VS Code/Cursor to bring the right tab/window forward. Without it granted, clicking still
  activates the app, just not the exact tab.
- **Notifications**, so it can alert you the moment a session is waiting on your approval. Answer
  the system's one-time prompt; you can toggle it later in System Settings → Notifications →
  MyAgents.

Nothing else is requested — the app is **not sandboxed** (by design, see
[`../CONTEXT.md`](../CONTEXT.md) D5: reading `~/.claude`/`~/.codex`, listing processes, and
focusing other apps don't fit inside the App Store sandbox), but it also never asks for Full Disk
Access, Accessibility, or Screen Recording — it doesn't need them.

## Privacy

Same contract as the Windows build:

- **Sessions/state:** read from the per-session JSON the hooks write to
  `~/.claude/statusbar/sessions.d/`, from Codex's own rollout files, and from which
  `claude`/`codex` processes are alive (via `libproc`/`sysctl` — public APIs only).
- **Claude usage:** from Claude Code's own statusline `rate_limits` (no token, no network).
- **Codex usage:** from Codex's own local `app-server` JSON-RPC (`account/rateLimits/read`) using
  its already-cached login — no token leaves your Mac, no undocumented HTTP endpoint is called.
- No backend, no telemetry, no crash reporter phoning home.
- Preferences (show usage, open-at-login) are the only thing stored, in
  `~/Library/Preferences/com.miguelangelramirez.myagents.mac.plist` (standard `UserDefaults`).

## Uninstall

1. In the app: **⚙ → Remove tracking** — this cleanly removes MyAgents' hook entries from
   `~/.claude/settings.json` (restoring any statusline you had before) and deletes
   `~/.claude/statusbar/`.
2. Then: `brew uninstall --zap myagents` (Homebrew installs) — `--zap` clears MyAgents' own
   preferences/saved state. If you installed by dragging the app to `/Applications`, just delete
   `MyAgentsMac.app` and, optionally,
   `~/Library/Preferences/com.miguelangelramirez.myagents.mac.plist`.

Step 1 before step 2 matters: `brew uninstall --zap` only ever touches MyAgents' own files, never
anything it wrote inside `~/.claude` or `~/.codex` (those are shared with Claude Code/Codex
themselves, so the app never lets a package manager touch them automatically).

## Build from source

Requires Xcode 26.6 and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`) — `MyAgentsMac.xcodeproj` is generated, never edited/committed by hand.

```bash
cd mac
xcodegen generate
xcodebuild -project MyAgentsMac.xcodeproj -scheme MyAgentsMac -configuration Debug test \
  -destination 'platform=macOS'                       # 183 unit tests, Core only (no UI target)
xcodebuild -project MyAgentsMac.xcodeproj -scheme MyAgentsMac -configuration Debug build \
  -destination 'platform=macOS'                       # runs on your Mac, ad-hoc signed
```

## App icon

`Resources/Assets.xcassets/AppIcon.appiconset` is generated, not hand-drawn in an image editor —
`scripts/IconArt.swift` draws the master 1024×1024 artwork with plain CoreGraphics (a dark
squircle plate + a ">" chevron in Claude orange `#D97757` and a cursor block in Codex teal
`#40C4B4` — no text, no gradients), and `scripts/generate-app-icon.sh` rasterizes every required
size with `sips` and writes `Contents.json`. Re-run it after changing the artwork:

```bash
./scripts/generate-app-icon.sh
xcodegen generate
```

## Release (maintainer)

See [`../PUBLISHING.md`](../PUBLISHING.md) → "macOS release checklist" for the full Developer ID +
notarization + Homebrew flow. Short version: `./scripts/build-release.sh` archives, exports
(Developer ID), notarizes, staples, zips, and prints the sha256 you paste into
`dist/Casks/myagents.rb` before pushing it to the tap.
