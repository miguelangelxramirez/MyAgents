using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using MyAgents.Models;

namespace MyAgents.Services;

/// <summary>
/// Finds and reads the per-session state files written by the hooks, across the
/// native Windows home AND every installed WSL distro. No server, no IPC: just
/// reads JSON files. See docs/state-schema.md.
/// </summary>
public sealed class SessionScanner
{
    private const int StaleSeconds = 7 * 24 * 60 * 60; // 7d backstop only; process LIVENESS decides openness (so suspend/resume never hides a live session)
    private const string Rel = @".claude\statusbar\sessions.d";
    private const string RelUnix = ".claude/statusbar/sessions.d";

    private List<(string Dir, string Origin)> _roots = new();
    private readonly Dictionary<string, (long Stamp, SessionState State)> _stateCache = new(StringComparer.OrdinalIgnoreCase);

    public SessionScanner() => RefreshRoots();

    /// <summary>Re-discover state directories (call on startup and on manual refresh).</summary>
    public void RefreshRoots()
    {
        var roots = new List<(string, string)>();

        // 1) Native Windows home.
        var win = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), Rel);
        roots.Add((win, "Windows"));

        // 2) Every running WSL distro. Prefer \\wsl.localhost and only fall back
        // to \\wsl$ when needed; probing both every second doubles UNC work.
        foreach (var distro in ListWslDistros())
        {
            foreach (var prefix in new[] { $@"\\wsl.localhost\{distro}", $@"\\wsl$\{distro}" })
            {
                var distroRoots = new List<(string, string)>();
                // root user
                var rootDir = Path.Combine(prefix, "root", RelUnix.Replace('/', '\\'));
                distroRoots.Add((rootDir, distro));
                // each /home/<user>
                var home = Path.Combine(prefix, "home");
                var usable = false;
                try
                {
                    if (Directory.Exists(home))
                    {
                        usable = true;
                        foreach (var u in Directory.GetDirectories(home))
                            distroRoots.Add((Path.Combine(u, RelUnix.Replace('/', '\\')), distro));
                    }
                    else if (Directory.Exists(rootDir)) usable = true;
                }
                catch { /* distro not mounted yet; ignore */ }
                if (!usable) continue;
                roots.AddRange(distroRoots);
                break;
            }
        }

        _roots = roots;
    }

    /// <summary>Scan all roots and return the live sessions, ordered for display.</summary>
    public List<SessionState> Scan()
    {
        long now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var result = new List<SessionState>();
        var seen = new HashSet<string>(StringComparer.Ordinal);

        foreach (var (dir, origin) in _roots)
        {
            string[] files;
            try
            {
                if (!Directory.Exists(dir)) continue;
                files = Directory.GetFiles(dir, "*.json");
            }
            catch { continue; }

            foreach (var f in files)
            {
                var s = TryReadCached(f);
                if (s is null) continue;
                s.SourcePath = f;
                s.Origin = origin;
                s.NowUnix = now;
                if (s.IsStale(StaleSeconds)) continue;
                if (string.IsNullOrEmpty(s.SessionId)) s.SessionId = Path.GetFileNameWithoutExtension(f);
                if (!seen.Add(s.SessionId)) continue; // dedup (same id seen via wsl.localhost + wsl$)
                // Prefer Claude's generated title from the transcript over the raw hook
                // prompt. The transcript path is a WSL path for WSL sessions → map it
                // to a UNC path the Windows app can actually open.
                var accessible = ToAccessible(s.Transcript, origin);
                var title = TranscriptTitle.Get(s.SessionId, accessible);
                if (title.Length > 0) s.Name = title;
                // Only for "thinking": one cheap stat to tell real streaming from a stalled turn.
                if (s.State == "thinking" && accessible.Length > 0)
                    try { s.TranscriptMtimeUnix = new DateTimeOffset(File.GetLastWriteTimeUtc(accessible)).ToUnixTimeSeconds(); } catch { }
                result.Add(s);
            }
        }

        // Attention first, then busy, then most-recently-active.
        return result
            .OrderByDescending(x => x.NeedsAttention)
            .ThenByDescending(x => x.IsBusy)
            .ThenByDescending(x => x.Ts)
            .ToList();
    }

    /// <summary>Map a session path to something the Windows app can open: WSL paths
    /// (/home/...) become \\wsl.localhost\&lt;distro&gt;\home\... using the row's origin.</summary>
    private static string ToAccessible(string path, string origin)
    {
        if (string.IsNullOrEmpty(path)) return "";
        if (origin == "Windows" || !path.StartsWith('/')) return path;
        return $@"\\wsl.localhost\{origin}" + path.Replace('/', '\\');
    }

    private static SessionState? TryRead(string file)
    {
        // The writer renames atomically, but reading across \\wsl.localhost can still
        // race; retry briefly and tolerate a transient partial/locked read.
        for (int attempt = 0; attempt < 2; attempt++)
        {
            try
            {
                using var fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
                using var sr = new StreamReader(fs, Encoding.UTF8);
                var json = sr.ReadToEnd();
                if (string.IsNullOrWhiteSpace(json)) return null;
                return JsonSerializer.Deserialize(json, SessionJsonContext.Default.SessionState);
            }
            catch (JsonException) { return null; }
            catch (IOException) { Thread.Sleep(15); }
            catch { return null; }
        }
        return null;
    }

    private SessionState? TryReadCached(string file)
    {
        long stamp;
        try { stamp = File.GetLastWriteTimeUtc(file).Ticks; }
        catch { return null; }

        if (_stateCache.TryGetValue(file, out var cached) && cached.Stamp == stamp)
            return Clone(cached.State);

        var s = TryRead(file);
        if (s is null) return null;
        _stateCache[file] = (stamp, Clone(s));
        return s;
    }

    private static SessionState Clone(SessionState s) => new()
    {
        State = s.State,
        Provider = s.Provider,
        Name = s.Name,
        Label = s.Label,
        Tool = s.Tool,
        Project = s.Project,
        Cwd = s.Cwd,
        Host = s.Host,
        TerminalHost = s.TerminalHost,
        SessionId = s.SessionId,
        TitleTag = s.TitleTag,
        Transcript = s.Transcript,
        Pid = s.Pid,
        StartedAt = s.StartedAt,
        Ts = s.Ts,
    };

    private static List<string> ListWslDistros() => Wsl.Distros().ToList();
}
