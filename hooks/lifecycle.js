#!/usr/bin/env node
// SessionStart/SessionEnd: create/remove the per-session state file and stamp
// the terminal title so the session is identifiable from the moment it opens.
// Unlike the upstream macOS app, this does NOT launch a GUI app via `open` —
// the Windows tray app runs persistently (or via "Start with Windows") and
// simply watches the sessions.d/ folders.
// Usage: node lifecycle.js <start|end>   (hook JSON, incl. session_id, on stdin)

// A status hook must NEVER disrupt the Claude session: swallow ANY error and exit 0.
process.on("uncaughtException", () => { try { process.exit(0); } catch (e) {} });
process.on("unhandledRejection", () => { try { process.exit(0); } catch (e) {} });

const fs = require("fs");
const C = require("./_common.js");

const event = process.argv[2];
const provider = process.argv[3] || "claude"; // "claude" | "codex"

let input = "", done = false;
process.stdin.on("data", (d) => (input += d));
process.stdin.on("end", () => run());
process.stdin.on("error", () => run());
setTimeout(run, 1000); // hooks always pipe stdin, but never hang the session

function run() {
  if (done) return; done = true;

  let p = {};
  try { p = JSON.parse(input || "{}"); } catch {}
  const sid = p.session_id || "";
  if (!sid) { process.exit(0); }

  const file = C.sessionFile(sid);
  const cwd = p.cwd || "";
  const project = cwd ? require("path").basename(cwd) : "";
  const ts = Math.floor(Date.now() / 1000);

  if (event === "start") {
    C.writeJsonAtomic(file, {
      state: "idle", label: "", provider, name: "", tool: "", project, cwd,
      host: C.host(), terminalHost: C.terminalHost(), sessionId: sid,
      transcript: p.transcript_path || "", pid: C.ownerPid(),
      startedAt: 0, ts,
    });
  } else if (event === "end") {
    try { fs.rmSync(file, { force: true }); } catch {}
  }

  process.exit(0);
}
