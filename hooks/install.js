#!/usr/bin/env node
// Standalone fallback installer (the app self-installs; use this only if you install
// hooks by hand). Merges our hooks + statusLine into ~/.claude/settings.json without
// clobbering yours, and copies the hook scripts to ~/.claude/statusbar/. Run once in
// EACH environment (inside WSL, and/or PowerShell) — each has its own home + settings.
// Kept in sync with HookInstaller.cs (the app installer).

const fs = require("fs");
const os = require("os");
const path = require("path");

const home = os.homedir();
const sbDir = path.join(home, ".claude", "statusbar");
const MARKER = "statusbar"; // every hook command we add points inside this dir
const settingsPath = path.join(home, ".claude", "settings.json");
const node = process.execPath;

const FILES = ["_common.js", "update.js", "lifecycle.js", "statusline.js"];

fs.mkdirSync(sbDir, { recursive: true });
fs.mkdirSync(path.join(sbDir, "sessions.d"), { recursive: true });
// Atomic copy (temp + rename) so a mid-write hiccup can never leave a 0-byte hook,
// which would break EVERY session (each hook requires _common.js).
for (const f of FILES) {
  const dest = path.join(sbDir, f);
  const tmp = dest + ".tmp";
  fs.writeFileSync(tmp, fs.readFileSync(path.join(__dirname, f)));
  fs.renameSync(tmp, dest);
}

const cmd = (evt) => `"${node}" "${path.join(sbDir, "update.js")}" ${evt}`;
const life = (evt) => `"${node}" "${path.join(sbDir, "lifecycle.js")}" ${evt}`;

let settings = {};
if (fs.existsSync(settingsPath)) {
  settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
  const bak = settingsPath + ".bak-ccapp";
  if (!fs.existsSync(bak)) fs.copyFileSync(settingsPath, bak);
}
settings.hooks = settings.hooks || {};

// We WANT Claude to title the tab (its task summary = the unique key the app matches
// for precise focus), so REMOVE any legacy disable flag a prior version set.
if (settings.env && settings.env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE !== undefined) {
  delete settings.env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE;
  if (Object.keys(settings.env).length === 0) delete settings.env;
}

const stripOurs = (arr) =>
  (arr || [])
    .map((entry) => ({
      ...entry,
      hooks: (entry.hooks || []).filter((h) => !(h.command || "").includes(MARKER)),
    }))
    .filter((entry) => (entry.hooks || []).length > 0);

const addUnmatched = (evt, command) => {
  settings.hooks[evt] = stripOurs(settings.hooks[evt]);
  settings.hooks[evt].push({ hooks: [{ type: "command", command }] });
};
const addMatched = (evt, command) => {
  settings.hooks[evt] = stripOurs(settings.hooks[evt]);
  settings.hooks[evt].push({ matcher: "*", hooks: [{ type: "command", command }] });
};

addUnmatched("UserPromptSubmit", cmd("prompt"));
addMatched("PreToolUse", cmd("pre"));
addMatched("PostToolUse", cmd("post"));
addUnmatched("Notification", cmd("notify"));
addMatched("PermissionRequest", cmd("permreq"));
addUnmatched("Stop", cmd("stop"));
addUnmatched("SessionStart", life("start"));
addUnmatched("SessionEnd", life("end"));

// statusLine: capture the official rate_limits (token-free). If you already had a
// statusline, CHAIN it — save the original so our wrapper runs it and uninstall can
// restore it. Preserve other fields (padding, etc.) — only swap the command.
const ourSL = `"${node}" "${path.join(sbDir, "statusline.js")}"`;
const sidecar = path.join(sbDir, "orig-statusline.txt");
const existingSL = settings.statusLine || null;
const exCmd = (existingSL && existingSL.command) || "";
if (existingSL && !exCmd.includes("statusline.js") && exCmd) {
  fs.writeFileSync(sidecar, exCmd);
  console.log("Chaining your existing statusline (saved to orig-statusline.txt).");
} else if (!existingSL) {
  try { fs.unlinkSync(sidecar); } catch {}
}
const slObj = existingSL || {};
slObj.type = "command";
slObj.command = ourSL;
settings.statusLine = slObj;

fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n");
console.log("Installed Claude Code App hooks + statusLine into", settingsPath);
console.log("Host:", process.env.WSL_DISTRO_NAME ? "WSL (" + process.env.WSL_DISTRO_NAME + ")" : process.platform);
console.log("Scripts copied to:", sbDir);
console.log("Restart any open Claude Code sessions to pick up the hooks.");
