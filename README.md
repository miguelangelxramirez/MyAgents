![Windows](https://img.shields.io/badge/platform-Windows-blue)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

# MyAgents

![MyAgents widget](docs/screenshots/firstimagewidget.png)

A lightweight, always-on-top **Windows** widget that watches **all your AI-coding terminals at once**.
See what every [Claude Code](https://claude.com/claude-code) and [Codex](https://developers.openai.com/codex)
session is doing (thinking / running a tool / awaiting permission / idle), jump to the exact terminal
tab with one click, and keep an eye on your 5h / 7d usage — **without reading any token or calling any
undocumented endpoint**.

Works whether you run the CLIs in **WSL** or **native Windows (PowerShell)**.

---



https://github.com/user-attachments/assets/350c4716-db66-4904-97b3-0ead7a5e613e


## What you get

- **One panel for every session.** A live row per Claude Code / Codex session across all your terminals — its **name**, **folder**, and **state** (thinking, tool, awaiting permission, idle).
- **Click-to-focus.** Click a row and the exact Windows Terminal **tab** for that session comes to the front (matched by the session's unique title via UI Automation).
- **Usage bars, live and token-free.** Your Claude **5h** / **7d** windows and your Codex **5h** / **7d** windows, with reset countdowns.
- **A little robot in the tray** whose colour reflects state; left-click toggles the widget.
- **Notifications** (toast + sound) the moment a session needs your permission.
- **Corner-anchored, premium widget** that grows upward from a bottom corner; drag it or pick a corner from the menu.
- **Self-installing.** It wires up its own Claude hooks + Codex managed hooks across Windows and every running WSL distro — you never run an install script.

![Usage bars](docs/screenshots/usage.png)

## Who this is for

Windows users who already have **Claude Code and/or Codex installed and signed in**, and who run **several
sessions at once** and want a single always-visible place to see what each is doing and jump to it.

It works whether your CLIs run in **WSL** or **native Windows**. Usage requires a **Pro/Max Claude** plan
and/or a **Codex** plan (the same accounts the CLIs use).

## Requirements

- Windows 10 or Windows 11
- [Claude Code](https://claude.com/claude-code) and/or [Codex](https://developers.openai.com/codex) installed and authenticated
- **Node.js** available in the environment each CLI runs in (the status hooks are tiny Node scripts)
- If you run the CLIs in WSL, that's fully supported (the app reads across `\\wsl.localhost`)

## Install

```powershell
winget install MiguelAngelRamirez.MyAgents
```

Or download the latest `MyAgents.exe` from the [Releases](https://github.com/OWNER/REPO/releases) page and run it directly (it's a self-contained single file — no install needed).

## Use

Launch it (double-click the exe / the **MyAgents** shortcut, or `winget`-installed command). It appears as a
**robot icon in the tray** and a **widget in the bottom-right corner**.

- **Click a session row** → focuses that session's terminal tab.
- **Click the tray robot** → shows/hides the widget. (Re-running the exe also brings the widget to the front — a reliable way to open it.)
- **Click the header bar** → collapse / expand the widget (both ways; the cursor turns into a hand).
- **⚙ menu** (opens away from the screen edge so it never covers the app): show/hide widget, **show usage**, **track Codex**, **Restart WSL**, export diagnostics, position, **Start with Windows**, repair / uninstall hooks.
- **Position** submenu (or drag-snap) puts the widget in any corner; on a bottom corner it grows upward.

> **▶ [Watch a short demo](docs/screenshots/videoopenandclosingapp.mp4)** — opening and closing the app. (Click to play it in GitHub's viewer.)

> **Tip:** enable **Start with Windows** from the ⚙ menu so it's always running and you never have to hunt for it.

### Sessions & focus

Each row shows three lines: **name** · **folder** · **state**. Claude's name is the task summary it generates
(`ai-title`); Codex's name is the session's first prompt. A finished-but-unopened session shows a small dot,
cleared when you click it. The left accent bar is the **provider colour** (Claude orange / Codex teal); the
moving glyph (a little robot) shows it's busy.

A session is considered **open while its `claude`/`codex` process is alive** — so the list survives reboots,
sleep/resume and idle, and a closed session disappears on its own.

### Usage

Usage is **opt-in** (off by default; enable **Show usage** in the ⚙ menu). When on:

- **Claude** comes from Claude Code's **official statusline `rate_limits`** — captured by a tiny statusline
  script we register (which also transparently runs any statusline you already had).
- **Codex** comes from Codex's **own local `app-server` RPC** (`account/rateLimits/read`) — the same
  mechanism [CodexBar](https://github.com/steipete/CodexBar) uses.

Both are **live, token-free, and official** — no OAuth token is read and no undocumented endpoint is called in
the public build. If Codex is at its limit or WSL is momentarily unavailable, Codex usage falls back to the
value it last wrote to its rollout file. A stale Claude reading (idle session) is greyed and labelled "N m ago"
rather than shown as if it were live.

### System tray icon

A small **robot**, tinted by state, or your **5h usage %** as a badge when usage is on. Left-click toggles the
widget. If you don't see it, click the tray overflow arrow (▲) and drag it out to keep it visible.

![Tray + menu](docs/screenshots/menubutton.png)

## Updating

- **winget:** `winget upgrade MiguelAngelRamirez.MyAgents` (or `winget upgrade --all`).
- **Portable exe:** download the newer `MyAgents.exe` from Releases and replace the old one.

Updates ship as **GitHub Releases**; winget tracks them, so there's no self-replacing auto-updater (which
antivirus tends to flag). See [PUBLISHING.md](PUBLISHING.md) for the release + winget flow.

## Diagnostics

⚙ menu → **Export diagnostics** writes a `.txt` (sessions, live processes, settings, recent perf/focus log —
**no tokens**) you can attach to an issue. Or set `CCAPP_DEBUG=1` before launching to log verbose diagnostics to
`%TEMP%\myagents.log`. Settings live at `%APPDATA%\MyAgents\settings.json`.

## Privacy & security

This project is **open source** — you can audit exactly what it does.

**The public build reads no tokens and calls no network usage endpoints.** Concretely:

- **Sessions/state:** read from the per-session JSON the hooks write to `~/.claude/statusbar/sessions.d/` and from Codex rollout files — plus which `claude`/`codex` processes are alive.
- **Claude usage:** captured from the data Claude Code itself feeds to your statusline (no token, no network).
- **Codex usage:** read from Codex's own local `app-server` RPC using your already-cached login (no token sent over the network, no undocumented HTTP endpoint).
- **Stored locally:** only UI preferences (corner, visibility, toggles) in `%APPDATA%\MyAgents\settings.json`.
- It does **not** send credentials anywhere, has no backend, and collects no telemetry.

> A separate **local-only** build flag (`USAGE_LOCAL`) keeps the old undocumented OAuth/`wham` endpoints as a
> fallback — that code is **compiled out of the public release**. See [PUBLISHING.md](PUBLISHING.md).

To remove everything cleanly, see [docs/uninstall.md](docs/uninstall.md) (⚙ menu → **Uninstall hooks** does it,
including restoring any statusline you had).

## How it works

1. On launch it **self-installs** its status hooks into `~/.claude/settings.json` (Windows + each running WSL distro) and Codex **managed** hooks under `/etc/codex`, plus a statusline capture script.
2. The hooks write one small JSON per session on each event (start, prompt, tool, permission, stop, end).
3. The app polls those files (plus live processes) a few times a second, off the UI thread, and renders the widget.
4. Clicking a row uses **UI Automation** to select the exact Windows Terminal tab by the session's unique title.
5. Usage refreshes about once a minute from the official statusline (Claude) and `app-server` RPC (Codex).

## Footprint (honest)

- **CPU:** negligible — all scanning runs on a background thread; the UI never blocks.
- **RAM:** ~**180 MB** (framework-dependent build) to ~**290 MB** (self-contained), flat over time (not a leak). That's the WPF + .NET cost; a 30–80 MB "featherweight" tray tool would mean a native rewrite, which isn't planned.

## Build (Windows, .NET 8 SDK)

```powershell
# Public (ship this): usage is token-free only
dotnet publish src/MyAgents -c Release -r win-x64 --self-contained true `
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true
# → bin\Release\net8.0-windows\win-x64\publish\MyAgents.exe
```

See [PUBLISHING.md](PUBLISHING.md) for the framework-dependent build, the `USAGE_LOCAL` flavor, and the release/winget steps.

## Credits & licence

MIT — see [LICENSE](LICENSE). Inspired by, and with attributions in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md):
[`m1ckc3s/claude-status-bar`](https://github.com/m1ckc3s/claude-status-bar) (the hook mechanism),
[`CodeZeno/Claude-Code-Usage-Monitor`](https://github.com/CodeZeno/Claude-Code-Usage-Monitor) (usage display),
[`onikan27/claude-code-monitor`](https://github.com/onikan27/claude-code-monitor), and
[`steipete/CodexBar`](https://github.com/steipete/CodexBar) (the Codex `app-server` RPC approach).
