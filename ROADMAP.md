# Claude Code App — Roadmap & tracking

Living doc. ✅ done · 🔆 doing now · ⏳ next · 💤 later

## Core (done)
- ✅ Self-installing hooks (Claude) across Windows + WSL — no manual scripts
- ✅ Live multi-session status (thinking / tool / permission / ready) + timer + spinner
- ✅ Click a row → focus the exact Windows Terminal **tab** (UI Automation)
- ✅ Claude usage bars 5h / 7d (opt-in) — keeps last good value on transient errors
- ✅ Codex sessions via rollout transcripts (no hooks, no `/hooks` trust)
- ✅ WPF glass UI, ⚙ menu, repair/uninstall hooks, start with Windows

## UX polish
- ✅ Widget **anchors to a screen corner**, grows **upward** (bottom corners); switch corner via Position menu or drag-snap
- ✅ When docked at a **bottom corner: header bar sits at the bottom**, usage just above it, sessions grow upward
- ✅ **3-line rows**: session **name** · folder · state
- ✅ **Name** = Claude's generated `aiTitle` from the transcript (fixed: map WSL transcript path → UNC; was unreadable). Codex name = first real user prompt (skips injected `environment_context`)
- ✅ **Provider colours**: Codex teal (not orange) + Claude/Codex badge
- ✅ **Pending dot**: finished-but-unopened marker, cleared on click
- ✅ **Slim scrollbar** (replaced the chunky default)

## Current hardening
- ✅ **Codex usage bars** at the bottom, read TOKEN-FREE from Codex's own rollout `rate_limits` (`primary`=5h / `secondary`=7d). The undocumented `wham/usage` endpoint is a local-only fallback behind `#if USAGE_LOCAL` (never in the public build). Robust: missing data shows "—", never a fake 0%.
- ✅ Usage bars coloured by **provider** (Claude orange / Codex teal) always, not by % — easy to tell apart.
- 🔆 Collapse flicker → switched backdrop from **Acrylic to Mica** (captured once, doesn't re-render on resize). Confirm it's gone.
- ✅ Collapse arrow is now **direction-aware** (bottom-dock: ▾ collapse / ▴ expand) so minimizing with the bar at the bottom feels natural.
- 🔆 **Responsiveness/perf hardening**: scan WSL/process/transcripts off the UI thread; log `perf:` timings with `CCAPP_DEBUG=1`.
- 🔆 **Session identity hardening**: preserve hook-provided names, avoid hook/transcript duplicate rows, and distinguish same-folder sessions with short ids.
- ✅ **Terminal host detection**: hooks persist `terminalHost` (`windows-terminal`, `vscode`, `cursor`, …). Windows Terminal still gets exact tab selection; VS Code/Cursor focus the matching IDE/workspace window.
- ✅ **Diagnostics export** from the tray menu: sessions, live processes, settings, and recent perf/focus logs without tokens.
- ⏳ **Per-session context %** on the right. Plan: read transcript tail for latest turn token usage (Claude: input+cache vs model window; Codex: rollout model_context_window). Approximate; cache + throttle.
- ✅ **Codex contract (final)**: discovery + liveness = process scan (always on). Precise state = **MANAGED hooks** — app writes scripts to `/etc/codex/cchooks/` (root) + `/etc/codex/requirements.toml` via `wsl -u root` → trusted by policy, **no `/hooks`, no `t`, survives auto-updates**. (Earlier managed failed because scripts were in the user home; managed needs a privileged dir.) Windows-native Codex (command_windows + %ProgramData% via elevated installer) = future. Transcript = name/state fallback.
- 📌 Note: hash-based trust is a **Codex** mechanism — managed hooks avoid it (what we use). **Claude Code hooks (settings.json) do NOT use hash-trust**, so an auto-update changing a Claude hook script would NOT re-prompt. A thin stable launcher is still nice (so auto-update needn't rewrite settings.json and risk user edits) but not for any hash reason.
- 🛡️ Safety: never overwrite a foreign `/etc/codex/requirements.toml` (enterprise/MDM) — only write if absent or carries our marker; else fall back to process/transcript. (Write-side twin of the delete guard.)
- ✅ Review hardening: usage opt-in (default OFF); hooks no longer write the terminal title (Claude's unique title is the focus key); /etc cleanup is marker-guarded; process scan also matches node-based claude/codex (excludes our hook scripts); same-folder sessions show a short-id so they're distinguishable; docs (README + state-schema) rewritten to the real contracts.
  - Future winget: Windows-native Codex → elevated installer writes `%ProgramData%\OpenAI\Codex\requirements.toml`.
- ✅ **Robust close detection (reaper)**: Codex has no SessionEnd, so sessions are removed when their owning CLI **process dies** (hook stores the owner pid via /proc walk; app checks live processes in WSL). Verified: a closed Codex session disappears within a few seconds. Also catches force-quit Claude.
- ⚠️ Minor: collapse/expand arrow has a brief flicker ("petardazo") — to polish.

## Next — ⏳
- ⏳ **Per-session context %** on the right (how full the context window is) — needs a reliable source per provider
- ⏳ Smarter Codex state (beyond working/idle) from the rollout
- ⏳ Native Windows Codex managed hooks (`windows_managed_dir` + `command_windows`) for PowerShell-only users
- ⏳ VS Code/Cursor companion extension for exact integrated-terminal selection (`terminal.show()` by session id)
- ✅ **Usage migrated to official, token-free sources** — Claude via the statusline `rate_limits` (captured by `statusline.js`, which transparently **chains** any existing user statusline: verbatim stdout, 1.5s timeout, never breaks the render; installer preserves `padding` and reverts cleanly), Codex via the rollout `rate_limits` (`primary`=5h/`secondary`=7d, read over `sh -s` STDIN). Undocumented OAuth endpoints now compile-out behind `#if USAGE_LOCAL` → **public build touches no token and no gray endpoint for either provider**. Stale windows (reset_at passed) are greyed + marked `~ last turn`, not shown as fresh. Verified live (Claude 73%, Codex 93/15).
- ✅ **UI**: usage bars equal width (fixed text column); clicking the collapsed bar expands it (corner-aware), not just the arrow.
- ✅ OSS release hardening: `THIRD-PARTY-NOTICES.md` (verbatim notices), `PUBLISHING.md` (gitleaks history sweep = blocking step 0; public-vs-local build; release + winget), `docs/uninstall.md` (clean revert incl. statusline restore), `packaging/winget/` portable manifests, hardened `.gitignore`.
- ⏳ Minimal tests around config writes (statusline chain round-trip, requirements.toml marker guard) — proven by hand; not yet codified.

## V1 — 💤
- 💤 Session history (visual timeline)
- 💤 Spend alerts + per-repo/project budgets
- 💤 "Who's spending what"
- 💤 Backups / export
- 💤 Per-project rules · permission policies

## Enterprise / later — 💤
- 💤 Audit log · weekly reports · anomaly alerts
- 💤 Multi-machine · Kanban agent view · other CLIs

## Known trade-offs
- Codex via transcripts shows only **recently active** sessions (idle ones vanish; hooks would know open+idle). Claude uses hooks → shows open+idle.
- Tab focus needs the WT tab title to reflect the cwd (default WSL/PowerShell prompt does this).
