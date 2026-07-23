using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace MyAgents.Services;

/// <summary>
/// Persisted UI preferences (floating widget position/visibility). Stored at
/// %APPDATA%\MyAgents\settings.json. All access is best-effort; a missing or
/// corrupt file just yields defaults.
/// </summary>
public sealed class AppSettings
{
    public string Corner { get; set; } = "bottom-right";  // bottom-right|bottom-left|top-right|top-left
    public bool WidgetVisible { get; set; } = true;
    public bool Collapsed { get; set; } = false;
    public bool CodexEnabled { get; set; } = false;   // also wire Codex CLI hooks (experimental)
    public bool UsageEnabled { get; set; } = false;    // opt-in: only read local tokens after the user turns this on
    public bool NotificationsEnabled { get; set; } = true;  // toast + sound when a session needs your permission
    public bool UpdateCheckEnabled { get; set; } = true;    // opt-out: check GitHub Releases for a newer version (the app's only network call)
    public long LastUpdateCheckUnix { get; set; } = 0;      // throttle the check to at most once/day
    public bool FirstRunDone { get; set; } = false;         // first launch enables autostart by default (reversible in ⚙) so it's always there

    [JsonIgnore]
    private static string Dir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MyAgents");
    [JsonIgnore]
    private static string FilePath => Path.Combine(Dir, "settings.json");

    public static AppSettings Load()
    {
        try
        {
            MigrateFromLegacyDir();
            if (File.Exists(FilePath))
            {
                var json = File.ReadAllText(FilePath);
                return JsonSerializer.Deserialize(json, AppJsonContext.Default.AppSettings) ?? new AppSettings();
            }
        }
        catch { }
        return new AppSettings();
    }

    /// <summary>One-time migration from the app's former name: COPY (never move) the old
    /// %APPDATA%\ClaudeCodeApp\settings.json to the new MyAgents dir if the new one doesn't
    /// exist yet, leaving the old file as a safety net.</summary>
    private static void MigrateFromLegacyDir()
    {
        try
        {
            if (File.Exists(FilePath)) return;   // already have new settings
            var legacy = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "ClaudeCodeApp", "settings.json");
            if (!File.Exists(legacy)) return;
            Directory.CreateDirectory(Dir);
            File.Copy(legacy, FilePath, overwrite: false);
        }
        catch { }
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Dir);
            var json = JsonSerializer.Serialize(this, AppJsonContext.Default.AppSettings);
            File.WriteAllText(FilePath, json);
        }
        catch { }
    }
}

[JsonSourceGenerationOptions(WriteIndented = true)]
[JsonSerializable(typeof(AppSettings))]
public partial class AppJsonContext : JsonSerializerContext
{
}
