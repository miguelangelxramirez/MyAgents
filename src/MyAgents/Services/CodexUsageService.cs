using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using MyAgents.Models;

namespace MyAgents.Services;

/// <summary>
/// Codex usage (5h / 7d). PRIMARY source = the rate_limits Codex itself writes into
/// its rollout JSONL (~/.codex/sessions/.../rollout-*.jsonl) on every turn — same data
/// the app already reads for name/state, so NO token and NO network. The undocumented
/// wham/usage endpoint is kept ONLY as a local fallback behind USAGE_LOCAL (it touches
/// the user's token and is a ToS grey area — never shipped in the public build).
///
/// Rollout schema (verified):
///   payload.rate_limits.primary   = 5h  (window_minutes 300):   { used_percent, resets_at }
///   payload.rate_limits.secondary = 7d  (window_minutes 10080): { used_percent, resets_at }
/// </summary>
public sealed class CodexUsageService
{
    public async Task<UsageInfo> FetchAsync()
    {
        // PRIMARY: Codex's own app-server RPC (account/rateLimits/read) — LIVE (incl. 100% at the
        // limit), TOKEN-FREE (uses the cached ~/.codex/auth.json), OFFICIAL (Codex's local RPC,
        // not the gray HTTP endpoint). Same mechanism CodexBar uses. Bounded so a slow/broken
        // codex can't hang the refresh; falls back to the rollout (lags) then, only in a LOCAL
        // build, the endpoint.
        var live = await Task.Run(ReadFromAppServerRpc).ConfigureAwait(false);
        if (live.Status == UsageStatus.Ok)
        {
            Log.Write($"codex-usage: rpc 5h={live.SessionPercent:0}% 7d={live.WeeklyPercent:0}%");
            return live;
        }
        var fromFile = ReadFromRollout();
        if (fromFile.Status == UsageStatus.Ok)
        {
            Log.Write($"codex-usage: rollout(fallback) 5h={fromFile.SessionPercent:0}% 7d={fromFile.WeeklyPercent:0}%");
            return fromFile;
        }
#if USAGE_LOCAL
        Log.Write("codex-usage: no rpc/rollout data → endpoint fallback (USAGE_LOCAL)");
        return await FetchFromEndpointAsync().ConfigureAwait(false);
#else
        return fromFile;  // public build never calls the undocumented endpoint
#endif
    }

    // ---- PRIMARY: live rate limits via `codex app-server` JSON-RPC (account/rateLimits/read) ----

    private static UsageInfo ReadFromAppServerRpc()
    {
        var i = RpcOne(null);                       // Windows-native codex
        if (i.Status == UsageStatus.Ok) return i;
        foreach (var distro in Wsl.Distros())       // then each WSL distro
        {
            i = RpcOne(distro);
            if (i.Status == UsageStatus.Ok) return i;
        }
        return new UsageInfo { Status = UsageStatus.Error };
    }

    private static UsageInfo RpcOne(string? distro)
    {
        Process? p = null;
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = distro is null ? "codex" : "wsl.exe",
                RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
                UseShellExecute = false, CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8, StandardInputEncoding = new UTF8Encoding(false),
            };
            var args = distro is null
                ? new[] { "-s", "read-only", "-a", "untrusted", "app-server" }
                : new[] { "-d", distro, "--", "codex", "-s", "read-only", "-a", "untrusted", "app-server" };
            foreach (var a in args) psi.ArgumentList.Add(a);

            p = Process.Start(psi);
            if (p is null) return new UsageInfo { Status = UsageStatus.Error };

            p.StandardInput.WriteLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"myagents\",\"title\":\"MyAgents\",\"version\":\"0.1.0\"}}}");
            p.StandardInput.WriteLine("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}");
            p.StandardInput.WriteLine("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"account/rateLimits/read\",\"params\":{}}");
            p.StandardInput.Flush();

            string? rpcLine = null;
            var reader = Task.Run(() =>
            {
                string? l;
                while ((l = p.StandardOutput.ReadLine()) != null)
                    if (l.Contains("\"id\":2", StringComparison.Ordinal)) { rpcLine = l; break; }
            });
            reader.Wait(12000);   // the read makes a network call → allow a few seconds

            return rpcLine is not null ? ParseRpcRateLimits(rpcLine) : new UsageInfo { Status = UsageStatus.Error };
        }
        catch { return new UsageInfo { Status = UsageStatus.Error }; }
        finally { try { if (p is not null && !p.HasExited) p.Kill(true); } catch { } p?.Dispose(); }
    }

    /// <summary>Parse the app-server account/rateLimits/read result (camelCase: usedPercent, resetsAt).</summary>
    private static UsageInfo ParseRpcRateLimits(string line)
    {
        try
        {
            using var doc = JsonDocument.Parse(line);
            if (!doc.RootElement.TryGetProperty("result", out var res)
                || !res.TryGetProperty("rateLimits", out var rl) || rl.ValueKind != JsonValueKind.Object)
                return new UsageInfo { Status = UsageStatus.Error };

            var info = new UsageInfo { Status = UsageStatus.Ok };
            var now = DateTimeOffset.UtcNow;
            bool any = false;
            if (Win(rl, "primary", out var p5, out var r5)) { info.SessionPercent = p5; info.SessionResetsAt = r5; info.SessionStale = r5 is { } d5 && d5 < now; any = true; }
            if (Win(rl, "secondary", out var p7, out var r7)) { info.WeeklyPercent = p7; info.WeeklyResetsAt = r7; info.WeeklyStale = r7 is { } d7 && d7 < now; any = true; }
            return any ? info : new UsageInfo { Status = UsageStatus.Error };
        }
        catch { return new UsageInfo { Status = UsageStatus.Error }; }

        static bool Win(JsonElement rl, string name, out double pct, out DateTimeOffset? reset)
        {
            pct = 0; reset = null;
            if (!rl.TryGetProperty(name, out var w) || w.ValueKind != JsonValueKind.Object) return false;
            if (w.TryGetProperty("usedPercent", out var up) && up.ValueKind == JsonValueKind.Number) pct = up.GetDouble();
            if (w.TryGetProperty("resetsAt", out var ra) && ra.ValueKind == JsonValueKind.Number)
                reset = DateTimeOffset.FromUnixTimeSeconds(ra.GetInt64());
            return true;
        }
    }

    // ---- PRIMARY: read the latest rate_limits from the rollout JSONL ----

    private static UsageInfo ReadFromRollout()
    {
        // Look ONLY at today's + yesterday's date dirs (like CodexScanner) — fast over UNC,
        // vs a recursive scan of years of rollouts. Check the NEWEST FEW files (rate_limits is
        // account-global, so any recent rollout works) until one yields a value. This is what
        // makes it robust: the single newest file might be a just-started session with no
        // rate_limits yet, but an older recent one has it.
        // Codex APPENDS to the rollout in the session's START-date dir (can be months old) with a
        // fresh mtime — so we must scan the whole tree by MTIME, not by date-dir name. Recursive
        // UNC enumeration is fast here (~0.4s). Grab candidates, pick the newest few below.
        var candidates = new List<FileInfo>();
        foreach (var root in RolloutSessionRoots())
        {
            try
            {
                if (!Directory.Exists(root)) continue;
                foreach (var f in new DirectoryInfo(root).EnumerateFiles("rollout-*.jsonl", SearchOption.AllDirectories))
                    candidates.Add(f);
            }
            catch { }
        }
        foreach (var f in candidates.OrderByDescending(f => f.LastWriteTimeUtc).Take(6))
        {
            var line = LastRateLimitsLine(f.FullName);
            if (line is not null) { var i = ParseRolloutLine(line); if (i.Status == UsageStatus.Ok) return i; }
        }
        return new UsageInfo { Status = UsageStatus.Error };  // no data -> "—", never a fake 0%
    }

    /// <summary>Codex sessions ROOTS to scan: Windows-native + each WSL home via UNC — works even
    /// when WSL command-exec is in E_UNEXPECTED (UNC file access still works).</summary>
    private static IEnumerable<string> RolloutSessionRoots()
    {
        yield return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "sessions");
        foreach (var distro in Wsl.Distros())
        {
            var found = new List<string>();
            foreach (var prefix in new[] { $@"\\wsl.localhost\{distro}", $@"\\wsl$\{distro}" })
            {
                try
                {
                    var homeBase = Path.Combine(prefix, "home");
                    if (Directory.Exists(homeBase))
                        foreach (var u in Directory.GetDirectories(homeBase))
                            found.Add(Path.Combine(u, ".codex", "sessions"));
                    var rootS = Path.Combine(prefix, "root", ".codex", "sessions");
                    if (Directory.Exists(rootS)) found.Add(rootS);
                    if (found.Count > 0) break;
                }
                catch { }
            }
            foreach (var d in found) yield return d;
        }
    }

    /// <summary>Tail-read a rollout (last 64 KB, UNC-safe) -> its last rate_limits line.</summary>
    private static string? LastRateLimitsLine(string file)
    {
        try
        {
            string text;
            using (var fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            {
                long from = Math.Max(0, fs.Length - 65536);
                fs.Seek(from, SeekOrigin.Begin);
                using var sr = new StreamReader(fs, Encoding.UTF8);
                text = sr.ReadToEnd();
            }
            string? last = null;
            foreach (var l in text.Split('\n'))
                if (l.Contains("\"rate_limits\"", StringComparison.Ordinal)) last = l;
            return last;
        }
        catch { return null; }
    }

    /// <summary>Parse one rollout JSONL line → UsageInfo (primary=5h, secondary=7d).</summary>
    private static UsageInfo ParseRolloutLine(string line)
    {
        try
        {
            using var doc = JsonDocument.Parse(line);
            var root = doc.RootElement;
            // rate_limits lives under payload; tolerate either shape.
            JsonElement rl;
            if (root.TryGetProperty("payload", out var pl) && pl.ValueKind == JsonValueKind.Object
                && pl.TryGetProperty("rate_limits", out var r1) && r1.ValueKind == JsonValueKind.Object)
                rl = r1;
            else if (root.TryGetProperty("rate_limits", out var r2) && r2.ValueKind == JsonValueKind.Object)
                rl = r2;
            else
                return new UsageInfo { Status = UsageStatus.Error };

            var info = new UsageInfo { Status = UsageStatus.Ok };
            var now = DateTimeOffset.UtcNow;
            bool any = false;
            if (Window(rl, "primary", out var p5, out var r5)) { info.SessionPercent = p5; info.SessionResetsAt = r5; info.SessionStale = r5 is { } d5 && d5 < now; any = true; }
            if (Window(rl, "secondary", out var p7, out var r7)) { info.WeeklyPercent = p7; info.WeeklyResetsAt = r7; info.WeeklyStale = r7 is { } d7 && d7 < now; any = true; }
            return any ? info : new UsageInfo { Status = UsageStatus.Error };
        }
        catch { return new UsageInfo { Status = UsageStatus.Error }; }

        static bool Window(JsonElement rl, string name, out double pct, out DateTimeOffset? reset)
        {
            pct = 0; reset = null;
            if (!rl.TryGetProperty(name, out var w) || w.ValueKind != JsonValueKind.Object) return false;
            if (w.TryGetProperty("used_percent", out var up) && up.ValueKind == JsonValueKind.Number) pct = up.GetDouble();
            if (w.TryGetProperty("resets_at", out var ra) && ra.ValueKind == JsonValueKind.Number)
                reset = DateTimeOffset.FromUnixTimeSeconds(ra.GetInt64());
            return true;
        }
    }

    private static List<string> RunningDistros() => Wsl.Distros().ToList();

#if USAGE_LOCAL
    // ---- LOCAL-ONLY fallback: the undocumented ChatGPT usage endpoint (token + network) ----

    private const string UsageUrl = "https://chatgpt.com/backend-api/wham/usage";

    private static readonly HttpClient Http = new(new HttpClientHandler
    { AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate })
    { Timeout = TimeSpan.FromSeconds(10) };

    private async Task<UsageInfo> FetchFromEndpointAsync()
    {
        var creds = DiscoverCreds();
        if (creds.Count == 0) return new UsageInfo { Status = UsageStatus.NoCredentials };

        bool sawAuth = false;
        foreach (var (token, account) in creds)
        {
            var info = await TryAsync(token, account).ConfigureAwait(false);
            if (info.Status == UsageStatus.Ok) return info;
            if (info.Status == UsageStatus.AuthNeeded) sawAuth = true;
        }
        return new UsageInfo { Status = sawAuth ? UsageStatus.AuthNeeded : UsageStatus.Error };
    }

    private async Task<UsageInfo> TryAsync(string token, string? account)
    {
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, UsageUrl);
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            req.Headers.TryAddWithoutValidation("User-Agent", "codex-cli");
            if (!string.IsNullOrEmpty(account)) req.Headers.TryAddWithoutValidation("ChatGPT-Account-Id", account);

            using var resp = await Http.SendAsync(req).ConfigureAwait(false);
            if (resp.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
                return new UsageInfo { Status = UsageStatus.AuthNeeded };
            if (!resp.IsSuccessStatusCode) return new UsageInfo { Status = UsageStatus.Error };

            var json = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
            return ParseEndpoint(json);
        }
        catch (Exception ex) { Log.Write("codex-usage: " + ex.Message); return new UsageInfo { Status = UsageStatus.Error }; }
    }

    private static UsageInfo ParseEndpoint(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (!doc.RootElement.TryGetProperty("rate_limit", out var rl) || rl.ValueKind != JsonValueKind.Object)
                return new UsageInfo { Status = UsageStatus.Error };

            var info = new UsageInfo { Status = UsageStatus.Ok };
            if (Window(rl, "primary_window", out var p5, out var r5)) { info.SessionPercent = p5; info.SessionResetsAt = r5; }
            if (Window(rl, "secondary_window", out var p7, out var r7)) { info.WeeklyPercent = p7; info.WeeklyResetsAt = r7; }
            return info;
        }
        catch { return new UsageInfo { Status = UsageStatus.Error }; }

        static bool Window(JsonElement rl, string name, out double pct, out DateTimeOffset? reset)
        {
            pct = 0; reset = null;
            if (!rl.TryGetProperty(name, out var w) || w.ValueKind != JsonValueKind.Object) return false;
            if (w.TryGetProperty("used_percent", out var up) && up.ValueKind == JsonValueKind.Number) pct = up.GetDouble();
            if (w.TryGetProperty("reset_at", out var ra) && ra.ValueKind == JsonValueKind.Number)
                reset = DateTimeOffset.FromUnixTimeSeconds(ra.GetInt64());
            return true;
        }
    }

    private static List<(string token, string? account)> DiscoverCreds()
    {
        var list = new List<(string, string?)>();
        var win = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "auth.json");
        TryFile(win, list);
        foreach (var distro in RunningDistros())
            TryWsl(distro, list);
        return list;
    }

    private static void TryFile(string path, List<(string, string?)> into)
    { try { if (File.Exists(path)) Add(File.ReadAllText(path), into); } catch { } }

    private static void TryWsl(string distro, List<(string, string?)> into)
    {
        try
        {
            var psi = new ProcessStartInfo("wsl.exe")
            { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true, StandardOutputEncoding = Encoding.UTF8 };
            foreach (var a in new[] { "-d", distro, "--", "sh", "-lc", "cat ~/.codex/auth.json" }) psi.ArgumentList.Add(a);
            using var p = Process.Start(psi);
            if (p is null) return;
            var outp = p.StandardOutput.ReadToEnd();
            p.WaitForExit(4000);
            Add(outp, into);
        }
        catch { }
    }

    private static void Add(string json, List<(string, string?)> into)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (!doc.RootElement.TryGetProperty("tokens", out var t) || t.ValueKind != JsonValueKind.Object) return;
            if (!t.TryGetProperty("access_token", out var at) || at.ValueKind != JsonValueKind.String) return;
            var token = at.GetString();
            if (string.IsNullOrWhiteSpace(token)) return;
            string? acc = t.TryGetProperty("account_id", out var ai) && ai.ValueKind == JsonValueKind.String ? ai.GetString() : null;
            if (!into.Any(x => x.Item1 == token)) into.Add((token!, acc));
        }
        catch { }
    }
#endif
}
