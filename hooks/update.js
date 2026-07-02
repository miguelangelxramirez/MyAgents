#!/usr/bin/env node
// Invoked by Claude Code hooks. Reads the hook JSON payload on stdin, maps the
// event to a status, and atomically writes ONE state file per session to
// ~/.claude/statusbar/sessions.d/<session_id>.json. This per-session model is
// what lets the Windows app show every terminal at once (the upstream macOS app
// kept a single global state.json and could only follow one session).
// Usage: node update.js <prompt|pre|post|notify|permreq|stop>

// A status hook must NEVER disrupt the Claude session: swallow ANY error and exit 0.
process.on("uncaughtException", () => { try { process.exit(0); } catch (e) {} });
process.on("unhandledRejection", () => { try { process.exit(0); } catch (e) {} });

const fs = require("fs");
const path = require("path");
const C = require("./_common.js");

const event = process.argv[2] || "";
const provider = process.argv[3] || "claude"; // "claude" | "codex" — same payload schema

const TOOL_LABELS = {
  Bash: "Running command", Edit: "Editing", Write: "Writing", MultiEdit: "Editing",
  NotebookEdit: "Editing", Read: "Reading", Grep: "Searching", Glob: "Searching",
  WebFetch: "Browsing web", WebSearch: "Searching web", Task: "Delegating",
  TodoWrite: "Planning",
};

let raw = "";
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", () => run());
process.stdin.on("error", () => run());
setTimeout(run, 1000); // hooks always pipe stdin, but never hang the session

let done = false;
function run() {
  if (done) return; done = true;

  let p = {};
  try { p = JSON.parse(raw || "{}"); } catch {}

  // Off by default; CLAUDE_STATUSBAR_DEBUG=1 logs every hook invocation.
  if (process.env.CLAUDE_STATUSBAR_DEBUG === "1") {
    try {
      fs.mkdirSync(C.dir, { recursive: true });
      fs.appendFileSync(path.join(C.dir, "hooks.log"),
        `${new Date().toISOString()} [${event}] host=${C.host()} tool=${p.tool_name || "-"} sid=${C.shortId(p.session_id)} keys=${Object.keys(p).join(",")}\n`);
    } catch {}
  }

  const sid = p.session_id || "";
  if (!sid) { process.exit(0); }

  const file = C.sessionFile(sid);
  let prev = {};
  try { prev = JSON.parse(fs.readFileSync(file, "utf8")); } catch {}

  const ts = Math.floor(Date.now() / 1000);
  // Sticky to the session's launch directory: keep the first cwd we saw so the
  // row label stays the project name even if the user (or a tool) `cd`s around.
  const cwd = prev.cwd || p.cwd || "";
  const project = cwd ? path.basename(cwd) : prev.project || "";
  let state = "idle", label = "", startedAt = prev.startedAt || 0;
  // Session "name" = the first prompt of the session (the topic), captured once.
  let name = prev.name || "";

  switch (event) {
    case "prompt":
      if (!name) name = String(p.prompt || "").replace(/\s+/g, " ").trim().slice(0, 90);
      state = "thinking"; label = "Thinking…"; startedAt = ts; break;
    case "pre": {
      const t = p.tool_name || "";
      // Known tools get a friendly verb; everything else (incl. long
      // mcp__server__method names) collapses to a generic "Using tool".
      state = "tool"; label = TOOL_LABELS[t] || "Using tool";
      if (!startedAt) startedAt = ts;
      break;
    }
    case "post":
      state = "thinking"; label = "Thinking…";
      if (!startedAt) startedAt = ts;
      break;
    case "notify": {
      // Only a permission prompt drives the icon here (CLI path; desktop uses
      // permreq). Ignore every other Notification (esp. the idle_prompt
      // "Claude is waiting for your input") so the row rests instead of parking
      // on a confusing "Awaiting permission".
      const m = (p.message || "").toLowerCase();
      const isPerm = p.notification_type === "permission_prompt" ||
        m.includes("permission") || m.includes("approve") || m.includes("allow");
      if (!isPerm) { process.exit(0); }
      state = "permission"; label = "Awaiting permission"; startedAt = 0;
      break;
    }
    case "permreq":
      // Desktop-app permission signal; not redundant with notify (CLI-only).
      state = "permission"; label = "Awaiting permission"; startedAt = 0; break;
    case "stop":
      state = "idle"; label = ""; startedAt = 0; break;
    default:
      process.exit(0);
  }

  const tag = C.titleTag(sid, project);
  const out = {
    state, label,
    provider, name,
    tool: p.tool_name || "",
    project, cwd,
    host: C.host(),
    terminalHost: C.terminalHost(),
    sessionId: sid,
    titleTag: tag,
    transcript: p.transcript_path || prev.transcript || "",
    pid: C.ownerPid(),
    startedAt, ts,
  };
  C.writeJsonAtomic(file, out);

  // NOTE: we no longer touch the terminal title. Claude Code sets its own unique
  // title (the task summary) which the app reads as the session name and matches
  // for click-to-focus. Writing our own title here would fight Claude's.

  process.exit(0);
}
