using System.IO;
using System.Text;
using System.Text.Json;

namespace MyAgents.Services;

/// <summary>
/// Extracts the human session title that Claude Code generates and writes into the
/// transcript as an {"type":"ai-title","aiTitle":"…"} line. Cached per session
/// (titles don't meaningfully change), so we read each transcript head only until
/// the title appears.
/// </summary>
public static class TranscriptTitle
{
    private static readonly Dictionary<string, (string Title, long CheckedAt)> Cache = new();
    private static readonly object Gate = new();
    private const int MaxLines = 150; // ai-title sits near the top
    private const int NegativeCacheSeconds = 20;

    public static string Get(string sessionId, string transcriptPath)
    {
        if (string.IsNullOrEmpty(sessionId)) return "";
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        lock (Gate)
            if (Cache.TryGetValue(sessionId, out var cached)
                && (cached.Title.Length > 0 || now - cached.CheckedAt < NegativeCacheSeconds))
                return cached.Title;

        var title = Read(transcriptPath);
        lock (Gate) Cache[sessionId] = (title, now);
        return title;
    }

    private static string Read(string path)
    {
        if (string.IsNullOrEmpty(path) || !SafeExists(path)) return "";
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            using var sr = new StreamReader(fs, Encoding.UTF8);
            string? line; int n = 0; string found = "";
            while ((line = sr.ReadLine()) != null && n++ < MaxLines)
            {
                if (!line.Contains("ai-title", StringComparison.Ordinal)) continue;
                try
                {
                    using var doc = JsonDocument.Parse(line);
                    if (doc.RootElement.TryGetProperty("aiTitle", out var t) && t.ValueKind == JsonValueKind.String)
                        found = (t.GetString() ?? "").Trim();   // keep last one within the head
                }
                catch { }
            }
            return found;
        }
        catch { return ""; }
    }

    private static bool SafeExists(string p) { try { return File.Exists(p); } catch { return false; } }
}
