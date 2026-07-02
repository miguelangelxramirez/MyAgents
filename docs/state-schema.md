# State contract (hooks ↔ .NET app)

The hooks write one JSON file per Claude Code session:

```
<home>/.claude/statusbar/sessions.d/<session_id>.json
```

`<home>` is the home of whatever environment the hook ran in:
- **Native Windows**: `C:\Users\<user>\.claude\statusbar\sessions.d\`
- **WSL**: `/home/<user>/.claude/statusbar/sessions.d/` → reachable from Windows at
  `\\wsl.localhost\<distro>\home\<user>\.claude\statusbar\sessions.d\`

The .NET app must scan the Windows path **and** each distro returned by `wsl -l -q`.

## File shape

```json
{
  "state":      "idle | thinking | tool | permission",
  "label":      "Thinking… | Editing | Running command | Awaiting permission | …",
  "tool":       "Edit",                      // raw tool name, may be empty
  "project":    "my-repo",                   // basename(cwd)
  "cwd":        "/home/me/my-repo",           // full path (for tooltip / future 'open folder')
  "host":       "windows | wsl:Ubuntu | linux | darwin",
  "terminalHost":"windows-terminal | vscode | cursor | conemu | ''",
  "sessionId":  "7f3a...full-id...",
  "titleTag":   "my-repo ⟦cc:7f3a9c1b⟧",     // exact substring stamped into the terminal title
  "transcript": "/path/to/transcript.jsonl",
  "pid":        12345,                         // hook's parent pid (best-effort)
  "startedAt":  1719400000,                    // unix secs; 0 when not in a timed turn
  "ts":         1719400042                     // unix secs; last update
}
```

## Liveness / cleanup rules for the reader

- A file in `sessions.d/` = a session the hooks believe is open. `SessionEnd` deletes it.
- Crashes can leave stale files. Treat a file as **stale** if `ts` is older than a threshold
  (suggest 60 min) and skip/grey it; optionally garbage-collect very old ones.
- `startedAt > 0` and `state ∈ {thinking, tool}` → show a running timer `now - startedAt`.
- `state == "permission"` → highlight (this session needs the human).

## Liveness contract

A session is **open** iff a `claude`/`codex` process exists for it. `ProcessScanner` runs
`pgrep` (plus node-cmdline matching) in each running WSL distro and returns each process's
pid + provider + cwd. The app keeps a session if its `pid` is live (precise) or, for pid-less
rows, if a process shares its `provider`+`cwd`; live processes with no session row are shown as
discovered (idle) rows. This survives reboots/idle and detects close without a SessionEnd event.

## Focus contract

Claude Code sets each terminal tab's title to a unique task summary, which the app reads from the
transcript as `name` (the `ai-title` line). For Windows Terminal, `TabFocuser` uses **UI
Automation** to find the `TabItem` whose title contains the session **name** (most specific), then
the cwd, and selects it (`SelectionItemPattern`); `WindowFocuser` then brings the window forward.

For VS Code/Cursor integrated terminals, external UI Automation cannot reliably select an exact
terminal instance. Hooks tag those sessions with `terminalHost`, and `WindowFocuser` focuses the
matching IDE/workspace window by title. Exact integrated-terminal selection would require a small
VS Code/Cursor companion extension using the editor API.

Hooks do **not** write the title (no controlling tty). UIA can select Windows Terminal background
tabs, unlike plain window-title matching.
