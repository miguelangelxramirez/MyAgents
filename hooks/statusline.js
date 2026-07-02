#!/usr/bin/env node
// Claude Code statusline wrapper — Managed by Claude Code App.
//
// Claude Code re-runs this on every render and feeds a JSON payload on stdin
// that includes the OFFICIAL `rate_limits` (5h/7d used_percentage + resets_at)
// for Pro/Max accounts. We capture that — no tokens, no API calls, no gray
// endpoint — to ~/.claude/statusbar/usage.json for the tray app to read.
//
// CRITICAL: this runs on the hot render path. Two hard rules:
//   1) Capture is fire-and-forget and MUST NEVER block or break the line.
//   2) If the user already had a statusline, we chain it TRANSPARENTLY: run
//      their original command with the same stdin and pass its stdout through
//      verbatim (ANSI included), with a timeout so a slow/hanging user script
//      can't freeze the render.
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

const SB = path.join(os.homedir(), ".claude", "statusbar");
const USAGE = path.join(SB, "usage.json");
const ORIG = path.join(SB, "orig-statusline.txt"); // the user's original command, if we chained one
const CHAIN_TIMEOUT_MS = 1500;

function readStdin() {
  return new Promise((resolve) => {
    let buf = "";
    try {
      process.stdin.setEncoding("utf8");
      process.stdin.on("data", (d) => (buf += d));
      process.stdin.on("end", () => resolve(buf));
      process.stdin.on("error", () => resolve(buf));
    } catch { resolve(buf); }
  });
}

// Write usage.json atomically. Never throws.
function capture(input) {
  try {
    const j = JSON.parse(input);
    const rl = j && j.rate_limits;
    if (!rl) return; // absent right after /clear or on non-Pro/Max plans — leave last good
    const pick = (w) => (w && typeof w.used_percentage === "number"
      ? { used_percent: w.used_percentage, reset_at: w.resets_at || 0 } : null);
    const out = {
      provider: "claude",
      source: "statusline",          // official channel, not the OAuth endpoint
      five_hour: pick(rl.five_hour),
      seven_day: pick(rl.seven_day),
      ts: Math.floor(Date.now() / 1000),
    };
    fs.mkdirSync(SB, { recursive: true });
    const tmp = USAGE + ".tmp" + process.pid;
    fs.writeFileSync(tmp, JSON.stringify(out));
    fs.renameSync(tmp, USAGE);
  } catch { /* capture must never break the render */ }
}

// Run the user's original statusline transparently; resolve to its stdout (or "").
function chain(input) {
  return new Promise((resolve) => {
    let cmd = "";
    try { cmd = fs.readFileSync(ORIG, "utf8").trim(); } catch { }
    if (!cmd) return resolve(null); // no chained command → we are the sole statusline
    let done = false;
    let child;
    const finish = (s) => {
      if (done) return;
      done = true;
      // Kill the whole process group (detached → child is group leader) so a
      // reparented grandchild (e.g. `sleep`) can't keep our stdout pipe open
      // and stall node past the timeout. Then free stdout so node can exit.
      try {
        if (child && child.pid) {
          if (process.platform === "win32") child.kill();
          else process.kill(-child.pid, "SIGKILL");   // POSIX: kill the whole detached group
        }
      } catch (e) { }
      try { if (child && child.stdout) child.stdout.destroy(); } catch { }
      resolve(s);
    };
    try {
      const isWin = process.platform === "win32";
      child = isWin
        ? spawn("cmd.exe", ["/d", "/s", "/c", cmd], { stdio: ["pipe", "pipe", "ignore"] })
        : spawn("sh", ["-c", cmd], { stdio: ["pipe", "pipe", "ignore"], detached: true });
      let out = "";
      child.stdout.on("data", (d) => (out += d));
      child.stdout.on("error", () => { });
      child.stdin.on("error", () => { });   // swallow EPIPE if their script closes stdin early
      child.on("close", () => finish(out));
      child.on("error", () => finish(""));   // their command missing/broken → don't break the line
      const t = setTimeout(() => finish(out), CHAIN_TIMEOUT_MS);
      if (t.unref) t.unref();
      try { child.stdin.write(input); child.stdin.end(); } catch { }
    } catch { finish(""); }
  });
}

// A minimal native line when we're the sole statusline (user had none before).
function ownLine(input) {
  try {
    const j = JSON.parse(input);
    const model = (j.model && (j.model.display_name || j.model.id)) || "";
    const rl = j.rate_limits || {};
    const p = (w) => (w && typeof w.used_percentage === "number" ? Math.round(w.used_percentage) + "%" : "—");
    const dir = j.workspace && j.workspace.current_dir ? path.basename(j.workspace.current_dir) : "";
    return [dir, model, `5h ${p(rl.five_hour)}`, `7d ${p(rl.seven_day)}`].filter(Boolean).join("  ·  ");
  } catch { return ""; }
}

(async () => {
  const input = await readStdin();
  // Fire-and-forget capture: synchronous + tiny, never blocks meaningfully.
  capture(input);
  const chained = await chain(input);
  // Show the chained output only when it produced something. If we're the sole
  // statusline (chained === null) OR the user's command failed / printed nothing
  // (chained === ""), fall back to our own minimal line — never an empty/broken line.
  process.stdout.write(chained && chained.length ? chained : ownLine(input));
})();
