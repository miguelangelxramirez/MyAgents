# Uninstalling cleanly

The app writes to a few places so it can show live status and official usage. It
is designed to **fully reverse** everything from the tray menu, and to never
clobber your own config.

## One-click

Tray icon → **Uninstall hooks**. Then quit the app. That reverts everything below.

## What it touches, and how it reverts

| Area | What we add | Reverted by uninstall |
|------|-------------|-----------------------|
| `~/.claude/settings.json` (Windows + each WSL home) | our `hooks` entries | removed (your other hooks untouched) |
| `~/.claude/settings.json` → `statusLine` | our wrapper; your original saved to `~/.claude/statusbar/orig-statusline.txt` | **your original command is restored** (padding/other fields kept); sidecar deleted. If you had none, ours is removed |
| `~/.claude/statusbar/` | `_common.js`, `update.js`, `lifecycle.js`, `statusline.js`, `sessions.d/`, `usage.json` | safe to delete the whole `statusbar/` folder |
| `/etc/codex/requirements.toml` + `/etc/codex/cchooks/` (only if Codex tracking was on) | managed hooks, **marker-guarded** | removed only if they carry our marker — a foreign/enterprise `requirements.toml` is never touched |
| `%APPDATA%\ClaudeCodeApp\settings.json` | the app's own UI prefs | delete the folder to remove |

We never write tokens anywhere, and the public build never calls a usage endpoint.

## Manual fallback (if you prefer to do it by hand)

```bash
# Claude hooks + statusline live in settings.json — uninstall restores statusLine
# from the sidecar automatically; to do it by hand, open the file and remove our
# hook entries / restore your statusLine command from:
cat ~/.claude/statusbar/orig-statusline.txt   # your original statusline command

# Remove our scripts + captures:
rm -rf ~/.claude/statusbar

# Codex managed hooks (only if you enabled Codex tracking). Marker-guarded:
grep -q 'Managed by Claude Code App' /etc/codex/requirements.toml 2>/dev/null \
  && sudo rm -f /etc/codex/requirements.toml && sudo rm -rf /etc/codex/cchooks
```

A backup of the first version of any file we edited is kept next to it as
`<file>.bak-ccapp`.
