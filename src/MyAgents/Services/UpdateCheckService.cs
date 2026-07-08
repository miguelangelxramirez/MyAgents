using System.Net.Http;
using System.Reflection;
using System.Runtime.Versioning;
using System.Text.Json;

namespace MyAgents.Services;

/// <summary>Passive, opt-out check for a newer GitHub Release. Does ONE unauthenticated GET to
/// GitHub's public, documented API, at most once per day (throttled via settings), off the UI
/// thread, fully guarded. It never downloads or replaces anything — the UI just shows a small
/// "update available" link to the Releases page. This is the app's only outbound network call and
/// it can be turned off from the ⚙ menu (see <see cref="AppSettings.UpdateCheckEnabled"/>).</summary>
[SupportedOSPlatform("windows")]
public static class UpdateCheckService
{
    private const string LatestApi = "https://api.github.com/repos/miguelangelxramirez/MyAgents/releases/latest";
    private const string ReleasesPage = "https://github.com/miguelangelxramirez/MyAgents/releases/latest";
    private static readonly HttpClient Http = CreateClient();

    private static HttpClient CreateClient()
    {
        var c = new HttpClient { Timeout = TimeSpan.FromSeconds(8) };
        // GitHub's API rejects requests that carry no User-Agent.
        c.DefaultRequestHeaders.UserAgent.ParseAdd("MyAgents-update-check");
        return c;
    }

    public readonly record struct Result(string Version, string Url);

    /// <summary>Returns the newer release (display version + Releases URL) if one exists, else null.
    /// Honours the opt-out flag and the once-a-day throttle. Best-effort: any failure (offline, rate
    /// limit, parse error) simply yields null and shows nothing.</summary>
    public static async Task<Result?> CheckAsync(AppSettings settings)
    {
        try
        {
            if (!settings.UpdateCheckEnabled) return null;

            long now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            if (now - settings.LastUpdateCheckUnix < 86_400) return null;   // at most once per day
            settings.LastUpdateCheckUnix = now;                            // count the attempt (even if it fails) so we don't hammer
            settings.Save();

            using var resp = await Http.GetAsync(LatestApi).ConfigureAwait(false);
            if (!resp.IsSuccessStatusCode) return null;
            var json = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);

            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (!root.TryGetProperty("tag_name", out var tagEl)) return null;
            var tag = tagEl.GetString();

            var latest = ParseVersion(tag);
            var current = ParseVersion(Assembly.GetExecutingAssembly().GetName().Version?.ToString());
            if (latest is null || current is null || latest <= current) return null;

            var url = root.TryGetProperty("html_url", out var urlEl) && urlEl.GetString() is { Length: > 0 } u
                ? u : ReleasesPage;
            return new Result(tag!.TrimStart('v', 'V'), url);
        }
        catch { return null; }
    }

    /// <summary>Parse "v0.1.2" / "0.1.2.0" / "0.1" into a normalised major.minor.patch Version,
    /// ignoring a leading 'v' and any pre-release/build suffix. Null if it isn't a version.</summary>
    private static Version? ParseVersion(string? s)
    {
        if (string.IsNullOrWhiteSpace(s)) return null;
        var parts = s.Trim().TrimStart('v', 'V').Split('.', '-', '+');
        if (parts.Length == 0 || !int.TryParse(parts[0], out _)) return null;
        int Get(int i) => i < parts.Length && int.TryParse(parts[i], out var n) ? n : 0;
        return new Version(Get(0), Get(1), Get(2));
    }
}
