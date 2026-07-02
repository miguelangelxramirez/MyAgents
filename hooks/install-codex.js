#!/usr/bin/env node
// Registers the SAME hook scripts with the OpenAI Codex CLI, tagged provider=codex,
// so Codex sessions show up in the widget alongside Claude. Codex's hook payload
// (session_id, cwd, tool_name) matches Claude's, so update.js/lifecycle.js work as-is.
//
// Codex hooks live in ~/.codex/hooks.json and are enabled by default, BUT Codex
// requires you to review & trust new hooks: run `/hooks` inside Codex after this.
// Codex hooks are experimental and Linux/WSL-only — run this from your WSL shell.

const fs = require("fs");
const os = require("os");
const path = require("path");

const home = os.homedir();
const sbDir = path.join(home, ".claude", "statusbar");      // shared state dir (our app)
const MARKER = "statusbar";
const codexDir = path.join(home, ".codex");
const hooksPath = path.join(codexDir, "hooks.json");
const node = process.execPath;

const FILES = ["_common.js", "update.js", "lifecycle.js"];

// Ensure our scripts exist in the shared dir (in case only Codex is set up).
fs.mkdirSync(path.join(sbDir, "sessions.d"), { recursive: true });
for (const f of FILES) fs.copyFileSync(path.join(__dirname, f), path.join(sbDir, f));

const updateDest = path.join(sbDir, "update.js");
const lifecycleDest = path.join(sbDir, "lifecycle.js");
const cmd = (evt) => `"${node}" "${updateDest}" ${evt} codex`;
const life = (evt) => `"${node}" "${lifecycleDest}" ${evt} codex`;

let cfg = {};
if (fs.existsSync(hooksPath)) {
  cfg = JSON.parse(fs.readFileSync(hooksPath, "utf8"));
  const bak = hooksPath + ".bak-ccapp";
  if (!fs.existsSync(bak)) fs.copyFileSync(hooksPath, bak);
} else {
  fs.mkdirSync(codexDir, { recursive: true });
}
cfg.hooks = cfg.hooks || {};

const stripOurs = (arr) =>
  (arr || [])
    .map((e) => ({ ...e, hooks: (e.hooks || []).filter((h) => !(h.command || "").includes(MARKER)) }))
    .filter((e) => (e.hooks || []).length > 0);

const add = (evt, command) => {
  cfg.hooks[evt] = stripOurs(cfg.hooks[evt]);
  cfg.hooks[evt].push({ hooks: [{ type: "command", command }] });
};

add("SessionStart", life("start"));
add("SessionEnd", life("end"));
add("UserPromptSubmit", cmd("prompt"));
add("PreToolUse", cmd("pre"));
add("PostToolUse", cmd("post"));
add("PermissionRequest", cmd("permreq"));
add("Notification", cmd("notify"));
add("Stop", cmd("stop"));

fs.writeFileSync(hooksPath, JSON.stringify(cfg, null, 2) + "\n");
console.log("Installed Codex hooks into", hooksPath);
console.log("Scripts (shared):", sbDir);
console.log("IMPORTANT: open Codex and run /hooks to review & TRUST these hooks, then restart Codex sessions.");
