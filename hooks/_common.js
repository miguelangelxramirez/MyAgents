// Shared helpers for the Claude Code App hooks (Windows + WSL + Linux + macOS).
// Copied verbatim into ~/.claude/statusbar/ by install.js, so it must have no
// external dependencies. Everything here is best-effort and must NEVER throw in
// a way that hangs or breaks a Claude Code session.

const fs = require("fs");
const os = require("os");
const path = require("path");

const dir = path.join(os.homedir(), ".claude", "statusbar");
const sessDir = path.join(dir, "sessions.d");

// A filesystem-safe session id (used as the per-session state filename).
const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64) || "unknown";

// Short, human-facing id used inside the terminal title tag.
const shortId = (s) => safeId(s).slice(0, 8);

// Where is this hook running? Drives how the Windows app finds the state files
// (native %USERPROFILE% vs \\wsl.localhost\<distro>\home\...) and labels rows.
function host() {
  if (process.platform === "win32") return "windows";
  if (process.env.WSL_DISTRO_NAME) return "wsl:" + process.env.WSL_DISTRO_NAME;
  if (process.platform === "linux") {
    try {
      if (fs.readFileSync("/proc/version", "utf8").toLowerCase().includes("microsoft"))
        return "wsl:unknown";
    } catch {}
    return "linux";
  }
  return process.platform;
}

function terminalHost() {
  const term = String(process.env.TERM_PROGRAM || "").toLowerCase();
  if (term === "vscode") {
    const hints = [
      process.env.TERM_PROGRAM_VERSION,
      process.env.VSCODE_GIT_ASKPASS_EXTRA_ARGS,
      process.env.VSCODE_IPC_HOOK_CLI,
      process.env.VSCODE_CWD,
      process.env.PWD,
    ].join(" ").toLowerCase();
    return hints.includes("cursor") ? "cursor" : "vscode";
  }
  if (process.env.WT_SESSION) return "windows-terminal";
  if (process.env.ConEmuPID) return "conemu";
  if (process.env.TERM_PROGRAM) return String(process.env.TERM_PROGRAM).slice(0, 40);
  return "";
}

// The unique, parseable tag we stamp into the terminal title. The Windows app
// matches the ⟦cc:<id>⟧ marker to find & focus the right window. The project
// name is just for the human reading the tab.
function titleTag(sessionId, project) {
  const id = shortId(sessionId);
  const proj = (project || "").slice(0, 24);
  return `${proj ? proj + " " : ""}⟦cc:${id}⟧`;
}

// Set the terminal-emulator title via an OSC sequence. Our stdio is piped to
// Claude Code, so we write to the *controlling terminal* directly:
//   - Unix/WSL: /dev/tty  (the real tty regardless of stdio redirection)
//   - Windows : \\.\CONOUT$  (the console screen buffer)
// Both are interpreted by modern terminals (Windows Terminal, conhost, etc).
// NOTE: needs real-machine validation; wrapped so a failure is silent.
function writeTitle(tag) {
  const seq = `]0;${tag}`;
  try {
    fs.writeFileSync(process.platform === "win32" ? "\\\\.\\CONOUT$" : "/dev/tty", seq);
  } catch {}
}

// Atomic write: write to a pid-suffixed temp file, then rename over the target.
function writeJsonAtomic(file, obj) {
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    const tmp = file + "." + process.pid + ".tmp";
    fs.writeFileSync(tmp, JSON.stringify(obj));
    fs.renameSync(tmp, file);
  } catch {}
}

function sessionFile(sessionId) {
  return path.join(sessDir, safeId(sessionId) + ".json");
}

// The pid of the owning CLI process (claude/codex), found by walking /proc up from
// our parent. The Windows app checks this pid's liveness to know when a session
// has closed — Codex has no SessionEnd event, so this is how its rows disappear.
// Falls back to the direct parent (and on Windows, where /proc is absent).
function ownerPid() {
  try {
    let pid = process.ppid || 0;
    for (let i = 0; i < 14 && pid > 1; i++) {
      let comm = "", cmd = "";
      try { comm = fs.readFileSync(`/proc/${pid}/comm`, "utf8").trim().toLowerCase(); } catch { break; }
      try { cmd = fs.readFileSync(`/proc/${pid}/cmdline`, "utf8").replace(/\0/g, " ").toLowerCase(); } catch {}
      // The long-lived CLI is a node/codex/claude process whose command line
      // mentions claude/codex — NOT a transient bash/sh tool wrapper (whose
      // cmdline may also mention claude). Gate on comm to skip those wrappers.
      const isCli = comm === "node" || comm.includes("codex") || comm.includes("claude");
      const mentions = comm.includes("claude") || comm.includes("codex")
                    || cmd.includes("claude") || cmd.includes("codex");
      if (isCli && mentions) return pid;
      let ppid = 0;
      try {
        const st = fs.readFileSync(`/proc/${pid}/stat`, "utf8");
        ppid = parseInt(st.slice(st.lastIndexOf(")") + 2).split(" ")[1], 10);
      } catch { break; }
      if (!ppid || ppid === pid) break;
      pid = ppid;
    }
  } catch {}
  return 0; // unknown → caller must NOT reap (never kill a live session by mistake)
}

module.exports = {
  dir, sessDir, safeId, shortId, host, terminalHost, titleTag, writeTitle, writeJsonAtomic, sessionFile, ownerPid,
};
