using System.IO;
using System.Text;
using System.Text.Json;
using MyAgents.Models;

namespace MyAgents.Services;

/// <summary>
/// Reads OpenAI Codex session state WITHOUT hooks — Codex already writes a rollout
/// transcript per session to ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl. We read
/// the metadata (id + cwd) and the file's recency to show what each Codex terminal
/// is doing. Zero setup, no /hooks trust (unlike the hook approach).
///
/// Trade-off vs hooks: we can only see RECENTLY ACTIVE sessions (a rollout that
/// isn't being written looks idle/gone), and state is coarser (working vs idle,
/// plus best-effort approval detection).
/// </summary>
public sealed class CodexScanner
{
    // Codex gives no SessionEnd, so we linger idle sessions (no rollout writes) for a
    // while instead of dropping them the moment they go quiet. Closed sessions also
    // linger up to this long as "idle" — the price of having no end signal.
    private const int ShowSeconds = 1800; // keep listing for 30 min after last activity
    private const int BusySeconds = 30;   // "working" if written to in the last 30 s (less flip-flop)

    private List<(string Dir, string Origin)> _roots = new();

    public CodexScanner() => RefreshRoots();

    public void RefreshRoots()
    {
        var roots = new List<(string, string)>();
        roots.Add((Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "sessions"), "Windows"));

        foreach (var distro in WslDistros())
            foreach (var prefix in new[] { $@"\\wsl.localhost\{distro}", $@"\\wsl$\{distro}" })
            {
                var distroRoots = new List<(string, string)>();
                var rootDir = Path.Combine(prefix, "root", ".codex", "sessions");
                distroRoots.Add((rootDir, distro));
                var home = Path.Combine(prefix, "home");
                var usable = false;
                try
                {
                    if (Directory.Exists(home))
                    {
                        usable = true;
                        foreach (var u in Directory.GetDirectories(home))
                            distroRoots.Add((Path.Combine(u, ".codex", "sessions"), distro));
                    }
                    else if (Directory.Exists(rootDir)) usable = true;
                }
                catch { }
                if (!usable) continue;
                roots.AddRange(distroRoots);
                break;
            }
        _roots = roots;
    }

    // Last good parse per session id (smooths transient read failures so a row
    // never blinks out while Codex is mid-write).
    private readonly Dictionary<string, (SessionState s, long okUnix)> _cache = new(StringComparer.Ordinal);

    // Persistent name-by-cwd (names don't change): lets a discovered/synthetic Codex row
    // (live process whose rollout went idle > ShowSeconds and was dropped) still show a real
    // name instead of just the folder — fixes the "sometimes only the folder" inconsistency.
    private readonly Dictionary<string, string> _namesByCwd = new(StringComparer.Ordinal);
    private readonly Dictionary<string, HashSet<string>> _cwdIds = new(StringComparer.Ordinal);
    private static string NormCwd(string c) => (c ?? "").Replace('\\', '/').TrimEnd('/').ToLowerInvariant();

    /// <summary>A cached real name for a session in this cwd — but ONLY when exactly one
    /// session has ever been seen there. If two Codex sessions shared a folder we can't tell
    /// which a nameless (synthetic) row belongs to, so we return null (show the folder) rather
    /// than risk labelling one session with another's name.</summary>
    public string? NameForCwd(string cwd)
    {
        var key = NormCwd(cwd);
        if (_cwdIds.TryGetValue(key, out var ids) && ids.Count > 1) return null;
        return _namesByCwd.TryGetValue(key, out var n) && n.Length > 0 ? n : null;
    }

    public List<SessionState> Scan()
    {
        long now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var nowLocal = DateTime.Now;
        var result = new List<SessionState>();
        var seen = new HashSet<string>(StringComparer.Ordinal);

        foreach (var (root, origin) in _roots)
        {
            if (!SafeExists(root)) continue;
            foreach (var day in new[] { nowLocal, nowLocal.AddDays(-1) })
            {
                var dir = Path.Combine(root, day.ToString("yyyy"), day.ToString("MM"), day.ToString("dd"));
                string[] files;
                try { if (!Directory.Exists(dir)) continue; files = Directory.GetFiles(dir, "rollout-*.jsonl"); }
                catch { continue; }

                foreach (var f in files)
                {
                    long ageSec;
                    try { ageSec = (long)(DateTime.Now - new FileInfo(f).LastWriteTime).TotalSeconds; }
                    catch { continue; }
                    if (ageSec > ShowSeconds) continue;

                    SessionState? s = null;
                    try { s = Parse(f, origin, now, ageSec); } catch { }
                    if (s is not null && !string.IsNullOrEmpty(s.SessionId))
                    {
                        if (!seen.Add(s.SessionId)) continue;
                        _cache[s.SessionId] = (s, now);
                        if (!string.IsNullOrEmpty(s.Name))
                        {
                            var k = NormCwd(s.Cwd);
                            _namesByCwd[k] = s.Name;
                            (_cwdIds.TryGetValue(k, out var set) ? set : (_cwdIds[k] = new(StringComparer.Ordinal))).Add(s.SessionId);
                        }
                        result.Add(s);
                    }
                }
            }
        }

        // Re-emit recently-good sessions that failed to read this pass (transient
        // lock while Codex writes) so they don't blink out.
        foreach (var (id, entry) in _cache)
        {
            if (seen.Contains(id)) continue;
            if (now - entry.okUnix > ShowSeconds) continue;
            entry.s.NowUnix = now;
            result.Add(entry.s);
            seen.Add(id);
        }
        // Drop very old cache entries.
        foreach (var id in _cache.Where(kv => now - kv.Value.okUnix > ShowSeconds).Select(kv => kv.Key).ToList())
            _cache.Remove(id);

        return result;
    }

    private static SessionState? Parse(string file, string origin, long now, long ageSec)
    {
        string? first = FirstLine(file);
        if (first is null) return null;

        string id = "", cwd = "";
        try
        {
            using var doc = JsonDocument.Parse(first);
            var root = doc.RootElement;
            if (root.TryGetProperty("payload", out var pl))
            {
                if (pl.TryGetProperty("id", out var idEl)) id = idEl.GetString() ?? "";
                if (pl.TryGetProperty("cwd", out var cwdEl)) cwd = cwdEl.GetString() ?? "";
            }
        }
        catch { return null; }
        if (id.Length == 0) return null;

        var (state, label) = InferState(file, ageSec);
        var project = string.IsNullOrEmpty(cwd) ? "" : Path.GetFileName(cwd.Replace('\\', '/').TrimEnd('/'));
        return new SessionState
        {
            Provider = "codex",
            SessionId = id,
            Cwd = cwd,
            Name = ExtractName(file),
            Project = project,
            State = state,
            Label = label,
            Host = origin == "Windows" ? "windows" : "wsl:" + origin,
            TerminalHost = "",
            Origin = origin,
            NowUnix = now,
            Ts = now - ageSec,
            StartedAt = state is "thinking" or "tool" ? now - Math.Min(ageSec, BusySeconds) : 0,
        };
    }

    /// <summary>Best-effort session name = the first user message in the rollout.</summary>
    private static string ExtractName(string file)
    {
        try
        {
            int n = 0;
            using var fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            using var sr = new StreamReader(fs, Encoding.UTF8);
            string? line;
            while ((line = sr.ReadLine()) != null && n++ < 60)
            {
                if (!line.Contains("\"user\"", StringComparison.Ordinal)) continue;
                using var doc = JsonDocument.Parse(line);
                if (!doc.RootElement.TryGetProperty("payload", out var pl)) continue;
                if (!pl.TryGetProperty("role", out var role) || role.GetString() != "user") continue;
                var text = ExtractText(pl).Replace("\n", " ").Trim();
                if (text.Length == 0) continue;
                // Skip Codex's injected context blocks — we want the real first prompt.
                if (text.StartsWith('<') || text.Contains("environment_context", StringComparison.OrdinalIgnoreCase)
                    || text.Contains("<user_instructions", StringComparison.OrdinalIgnoreCase)
                    || text.Contains("# AGENTS.md", StringComparison.OrdinalIgnoreCase)) continue;
                return text;
            }
        }
        catch { }
        return "";
    }

    private static string ExtractText(JsonElement payload)
    {
        if (!payload.TryGetProperty("content", out var content)) return "";
        if (content.ValueKind == JsonValueKind.String) return Trim(content.GetString());
        if (content.ValueKind == JsonValueKind.Array)
            foreach (var part in content.EnumerateArray())
                if (part.TryGetProperty("text", out var t) && t.ValueKind == JsonValueKind.String)
                    return Trim(t.GetString());
        return "";
        static string Trim(string? s) => (s ?? "").Length > 90 ? s![..90] : (s ?? "");
    }

    private static (string state, string label) InferState(string file, long ageSec)
    {
        // Best-effort: scan the tail for an approval request (permission) or activity.
        var tail = Tail(file, 4096);
        bool approval = tail.Contains("approval", StringComparison.OrdinalIgnoreCase)
                     && tail.Contains("request", StringComparison.OrdinalIgnoreCase)
                     && ageSec < 60;
        if (approval) return ("permission", "Awaiting your approval");
        if (ageSec <= BusySeconds) return ("tool", "Working");
        return ("idle", "");
    }

    private static string? FirstLine(string file)
    {
        try
        {
            using var fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            using var sr = new StreamReader(fs, Encoding.UTF8);
            return sr.ReadLine();
        }
        catch { return null; }
    }

    private static string Tail(string file, int bytes)
    {
        try
        {
            using var fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            long start = Math.Max(0, fs.Length - bytes);
            fs.Seek(start, SeekOrigin.Begin);
            using var sr = new StreamReader(fs, Encoding.UTF8);
            return sr.ReadToEnd();
        }
        catch { return ""; }
    }

    private static bool SafeExists(string dir) { try { return Directory.Exists(dir); } catch { return false; } }

    private static List<string> WslDistros()
    {
        var list = new List<string>();
        try
        {
            var psi = new System.Diagnostics.ProcessStartInfo("wsl.exe", "-l --running -q")
            { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true, StandardOutputEncoding = Encoding.Unicode };
            using var p = System.Diagnostics.Process.Start(psi);
            if (p is null) return list;
            var outp = p.StandardOutput.ReadToEnd(); p.WaitForExit(5000);
            foreach (var raw in outp.Split('\n'))
            {
                var n = raw.Replace("\r", "").Replace("\0", "").Trim();
                if (n.Length > 0) list.Add(n);
            }
        }
        catch { }
        return list;
    }
}
