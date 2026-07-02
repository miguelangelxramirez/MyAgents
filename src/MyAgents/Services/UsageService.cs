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
/// Claude usage (5h / 7d). PRIMARY source = the OFFICIAL rate_limits Claude Code feeds to
/// the statusline, which our statusline.js captures to ~/.claude/statusbar/usage.json —
/// NO token, NO network, sanctioned channel. The undocumented OAuth usage endpoint is kept
/// ONLY as a local fallback behind USAGE_LOCAL (token + ToS grey area; never in the public build).
///
/// usage.json schema (written by hooks/statusline.js):
///   { five_hour: { used_percent, reset_at(unix) }, seven_day: { used_percent, reset_at }, ts }
/// </summary>
public sealed class UsageService
{
    public async Task<UsageInfo> FetchAsync()
    {
        var fromFile = ReadUsageJson();
        if (fromFile.Status == UsageStatus.Ok)
        {
            Log.Write($"usage: statusline 5h={fromFile.SessionPercent:0}% 7d={fromFile.WeeklyPercent:0}%");
            return fromFile;
        }
#if USAGE_LOCAL
        Log.Write("usage: no fresh statusline capture → endpoint fallback (USAGE_LOCAL)");
        return await FetchFromEndpointAsync().ConfigureAwait(false);
#else
        await Task.CompletedTask;
        return fromFile;  // public build never calls the undocumented endpoint
#endif
    }

    // ---- PRIMARY: read the official capture from usage.json (Windows + each WSL home) ----

    private static UsageInfo ReadUsageJson()
    {
        UsageInfo best = new() { Status = UsageStatus.Error };
        long bestTs = -1;

        void Consider(string? json)
        {
            if (string.IsNullOrWhiteSpace(json)) return;
            var (info, ts) = ParseUsageJson(json);
            if (info.Status == UsageStatus.Ok && ts >= bestTs) { best = info; bestTs = ts; }
        }

        // Windows-native home (fast, local).
        try
        {
            var win = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                                   ".claude", "statusbar", "usage.json");
            if (File.Exists(win)) Consider(File.ReadAllText(win));
        }
        catch { }

        // Each running WSL home via UNC (\\wsl.localhost\...). We read the FILE directly (not
        // `wsl cat`) so usage still works when the WSL SERVICE is in E_UNEXPECTED — UNC file
        // access keeps working when command-exec dies. BOUNDED with a timeout because a flaky
        // WSL can make even UNC calls stall, and this must never hang the usage refresh.
        try
        {
            var distros = ListRunningWslDistros();
            Task.Run(() =>
            {
                foreach (var distro in distros)
                {
                    foreach (var prefix in new[] { $@"\\wsl.localhost\{distro}", $@"\\wsl$\{distro}" })
                    {
                        try
                        {
                            var homeBase = Path.Combine(prefix, "home");
                            bool usable = false;
                            if (Directory.Exists(homeBase))
                            {
                                usable = true;
                                foreach (var u in Directory.GetDirectories(homeBase))
                                {
                                    var f = Path.Combine(u, ".claude", "statusbar", "usage.json");
                                    if (File.Exists(f)) Consider(File.ReadAllText(f));
                                }
                            }
                            var rootF = Path.Combine(prefix, "root", ".claude", "statusbar", "usage.json");
                            if (File.Exists(rootF)) { usable = true; Consider(File.ReadAllText(rootF)); }
                            if (usable) break;
                        }
                        catch { }
                    }
                }
            }).Wait(3000);
        }
        catch { }
        return best;
    }

    private static (UsageInfo info, long ts) ParseUsageJson(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            var info = new UsageInfo { Status = UsageStatus.Ok };
            var now = DateTimeOffset.UtcNow;
            bool any = false;
            if (Bucket(root, "five_hour", out var p5, out var r5)) { info.SessionPercent = p5; info.SessionResetsAt = r5; info.SessionStale = r5 is { } d5 && d5 < now; any = true; }
            if (Bucket(root, "seven_day", out var p7, out var r7)) { info.WeeklyPercent = p7; info.WeeklyResetsAt = r7; info.WeeklyStale = r7 is { } d7 && d7 < now; any = true; }
            if (!any) return (new UsageInfo { Status = UsageStatus.Error }, -1);
            long ts = root.TryGetProperty("ts", out var t) && t.ValueKind == JsonValueKind.Number ? t.GetInt64() : 0;
            info.CapturedAtUnix = ts;
            return (info, ts);
        }
        catch { return (new UsageInfo { Status = UsageStatus.Error }, -1); }

        static bool Bucket(JsonElement root, string name, out double pct, out DateTimeOffset? reset)
        {
            pct = 0; reset = null;
            if (!root.TryGetProperty(name, out var w) || w.ValueKind != JsonValueKind.Object) return false;
            if (w.TryGetProperty("used_percent", out var up) && up.ValueKind == JsonValueKind.Number) pct = up.GetDouble();
            if (w.TryGetProperty("reset_at", out var ra) && ra.ValueKind == JsonValueKind.Number && ra.GetInt64() > 0)
                reset = DateTimeOffset.FromUnixTimeSeconds(ra.GetInt64());
            return true;
        }
    }

    private static List<string> ListRunningWslDistros() => Wsl.Distros().ToList();

#if USAGE_LOCAL
    // ---- LOCAL-ONLY fallback: the undocumented OAuth usage endpoint (token + network) ----

    private const string UsageUrl = "https://api.anthropic.com/api/oauth/usage";

    private static readonly HttpClient Http = new(new HttpClientHandler
    {
        AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate,
    })
    { Timeout = TimeSpan.FromSeconds(10) };

    private async Task<UsageInfo> FetchFromEndpointAsync()
    {
        var tokens = DiscoverTokens();
        if (tokens.Count == 0) return new UsageInfo { Status = UsageStatus.NoCredentials };

        bool sawAuth = false;
        foreach (var token in tokens)
        {
            var info = await TryUsageAsync(token).ConfigureAwait(false);
            if (info.Status == UsageStatus.Ok) return info;
            if (info.Status == UsageStatus.AuthNeeded) sawAuth = true;
        }
        return new UsageInfo { Status = sawAuth ? UsageStatus.AuthNeeded : UsageStatus.Error };
    }

    private async Task<UsageInfo> TryUsageAsync(string token)
    {
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, UsageUrl);
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            req.Headers.TryAddWithoutValidation("anthropic-beta", "oauth-2025-04-20");

            using var resp = await Http.SendAsync(req).ConfigureAwait(false);
            if (resp.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
                return new UsageInfo { Status = UsageStatus.AuthNeeded };
            if (!resp.IsSuccessStatusCode) return new UsageInfo { Status = UsageStatus.Error };

            var json = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
            return ParseEndpoint(json);
        }
        catch (Exception ex)
        {
            Log.Write("usage: request failed: " + ex.Message);
            return new UsageInfo { Status = UsageStatus.Error };
        }
    }

    private static UsageInfo ParseEndpoint(string json)
    {
        var info = new UsageInfo { Status = UsageStatus.Ok };
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.TryGetProperty("five_hour", out var h5) && h5.ValueKind == JsonValueKind.Object)
            {
                info.SessionPercent = h5.TryGetProperty("utilization", out var u) ? u.GetDouble() : 0;
                info.SessionResetsAt = ParseIso(h5);
            }
            if (root.TryGetProperty("seven_day", out var h7) && h7.ValueKind == JsonValueKind.Object)
            {
                info.WeeklyPercent = h7.TryGetProperty("utilization", out var u) ? u.GetDouble() : 0;
                info.WeeklyResetsAt = ParseIso(h7);
            }
        }
        catch { return new UsageInfo { Status = UsageStatus.Error }; }
        return info;

        static DateTimeOffset? ParseIso(JsonElement bucket)
            => bucket.TryGetProperty("resets_at", out var r) && r.ValueKind == JsonValueKind.String
               && DateTimeOffset.TryParse(r.GetString(), out var dt) ? dt : null;
    }

    private static List<string> DiscoverTokens()
    {
        var tokens = new List<string>();
        var winCreds = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", ".credentials.json");
        TryReadFileToken(winCreds, tokens);
        foreach (var distro in ListRunningWslDistros())
            TryReadWslToken(distro, tokens);
        return tokens;
    }

    private static void TryReadFileToken(string path, List<string> into)
    {
        try
        {
            if (!File.Exists(path)) return;
            var token = ExtractToken(File.ReadAllText(path));
            if (token is not null && !into.Contains(token)) into.Add(token);
        }
        catch { }
    }

    private static void TryReadWslToken(string distro, List<string> into)
    {
        try
        {
            var psi = new ProcessStartInfo("wsl.exe")
            { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true, StandardOutputEncoding = Encoding.UTF8 };
            psi.ArgumentList.Add("-d"); psi.ArgumentList.Add(distro);
            psi.ArgumentList.Add("--"); psi.ArgumentList.Add("sh"); psi.ArgumentList.Add("-lc");
            psi.ArgumentList.Add("cat ~/.claude/.credentials.json");
            using var p = Process.Start(psi);
            if (p is null) return;
            var content = p.StandardOutput.ReadToEnd();
            p.WaitForExit(4000);
            var token = ExtractToken(content);
            if (token is not null && !into.Contains(token)) into.Add(token);
        }
        catch { }
    }

    private static string? ExtractToken(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.TryGetProperty("claudeAiOauth", out var oauth) &&
                oauth.TryGetProperty("accessToken", out var at) &&
                at.ValueKind == JsonValueKind.String)
            {
                var token = at.GetString();
                return string.IsNullOrWhiteSpace(token) ? null : token;
            }
        }
        catch { }
        return null;
    }
#endif
}
