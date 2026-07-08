using System.Text.Json.Serialization;

namespace MyAgents.Models;

/// <summary>
/// One Claude Code session, as written by the Node hooks to
/// ~/.claude/statusbar/sessions.d/&lt;id&gt;.json. See docs/state-schema.md.
/// </summary>
public sealed class SessionState
{
    [JsonPropertyName("state")] public string State { get; set; } = "idle";
    [JsonPropertyName("provider")] public string Provider { get; set; } = "claude";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("label")] public string Label { get; set; } = "";
    [JsonPropertyName("tool")] public string Tool { get; set; } = "";
    [JsonPropertyName("project")] public string Project { get; set; } = "";
    [JsonPropertyName("cwd")] public string Cwd { get; set; } = "";
    [JsonPropertyName("host")] public string Host { get; set; } = "";
    [JsonPropertyName("terminalHost")] public string TerminalHost { get; set; } = "";
    [JsonPropertyName("sessionId")] public string SessionId { get; set; } = "";
    [JsonPropertyName("titleTag")] public string TitleTag { get; set; } = "";
    [JsonPropertyName("transcript")] public string Transcript { get; set; } = "";
    [JsonPropertyName("pid")] public long Pid { get; set; }
    [JsonPropertyName("startedAt")] public long StartedAt { get; set; }
    [JsonPropertyName("ts")] public long Ts { get; set; }

    // ---- Not serialized; filled in by the scanner ----

    /// <summary>Where the file lives (used as a stable key / dedup).</summary>
    [JsonIgnore] public string SourcePath { get; set; } = "";

    /// <summary>Friendly origin label, e.g. "Windows" or "Ubuntu".</summary>
    [JsonIgnore] public string Origin { get; set; } = "";

    /// <summary>Unix seconds (UTC) when this file was last scanned.</summary>
    [JsonIgnore] public long NowUnix { get; set; }

    /// <summary>The reliable substring to match in a window title (avoids the ⟦ ⟧ brackets).</summary>
    [JsonIgnore]
    public string FocusMarker
    {
        get
        {
            // Mirrors the JS shortId(): sanitize, take first 8 chars.
            var safe = new string((SessionId ?? "")
                .Where(c => char.IsLetterOrDigit(c) || c is '_' or '.' or '-')
                .Take(8).ToArray());
            return "cc:" + safe;
        }
    }

    [JsonIgnore] public bool NeedsAttention => State == "permission";
    [JsonIgnore] public bool IsBusy => State is "thinking" or "tool";

    /// <summary>Seconds elapsed in the current turn, or 0 if not timing.</summary>
    [JsonIgnore]
    public long ElapsedSeconds =>
        StartedAt > 0 && IsBusy && NowUnix >= StartedAt ? NowUnix - StartedAt : 0;

    /// <summary>Stale if we haven't heard from it in a while (crash safety net).</summary>
    public bool IsStale(int thresholdSeconds) => NowUnix - Ts > thresholdSeconds;
}

[JsonSourceGenerationOptions(PropertyNameCaseInsensitive = true)]
[JsonSerializable(typeof(SessionState))]
public partial class SessionJsonContext : JsonSerializerContext
{
}
