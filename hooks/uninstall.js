#!/usr/bin/env node
// Removes ONLY our hooks + statusLine from ~/.claude/settings.json and deletes the
// statusbar scripts. Leaves any other hooks you have untouched, and RESTORES your
// original statusline if we chained one. Run once per environment (WSL / PowerShell).
// Kept in sync with HookInstaller.StripFile.

const fs = require("fs");
const os = require("os");
const path = require("path");

const home = os.homedir();
const sbDir = path.join(home, ".claude", "statusbar");
const MARKER = "statusbar";
const settingsPath = path.join(home, ".claude", "settings.json");

if (fs.existsSync(settingsPath)) {
  const settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));

  if (settings.env && settings.env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE !== undefined) {
    delete settings.env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE;
    if (Object.keys(settings.env).length === 0) delete settings.env;
  }

  if (settings.hooks) {
    for (const evt of Object.keys(settings.hooks)) {
      settings.hooks[evt] = (settings.hooks[evt] || [])
        .map((entry) => ({
          ...entry,
          hooks: (entry.hooks || []).filter((h) => !(h.command || "").includes(MARKER)),
        }))
        .filter((entry) => (entry.hooks || []).length > 0);
      if (settings.hooks[evt].length === 0) delete settings.hooks[evt];
    }
    if (Object.keys(settings.hooks).length === 0) delete settings.hooks;
  }

  // statusLine: if it's OURS, restore your chained original (from the sidecar, read
  // BEFORE we delete the folder below) or remove ours. Never leave settings pointing
  // at a statusline.js we're about to delete.
  if (settings.statusLine && (settings.statusLine.command || "").includes("statusline.js")) {
    let orig = "";
    try { orig = fs.readFileSync(path.join(sbDir, "orig-statusline.txt"), "utf8").trim(); } catch {}
    if (orig && typeof settings.statusLine === "object") settings.statusLine.command = orig; // keep padding/etc.
    else delete settings.statusLine;
  }

  fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n");
  console.log("Removed Claude Code App hooks + statusLine from", settingsPath);
}

try { fs.rmSync(sbDir, { recursive: true, force: true }); console.log("Removed", sbDir); } catch {}
console.log("Restart any open Claude Code sessions to drop the hooks.");
