using Microsoft.Win32;

namespace MyAgents.Services;

/// <summary>Toggles "Start with Windows" via the per-user Run registry key.</summary>
public static class StartupManager
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "MyAgents";

    /// <summary>After the rename, a stale legacy "ClaudeCodeApp" Run entry would point at the old
    /// exe (gone) → the app silently stops starting with Windows. Remove it, and if it WAS enabled,
    /// re-point the new entry at the current exe. Call once at startup.</summary>
    public static void MigrateLegacyName()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
            if (key is null) return;
            bool wasEnabled = key.GetValue("ClaudeCodeApp") is not null;
            if (!wasEnabled) return;
            key.DeleteValue("ClaudeCodeApp", throwOnMissingValue: false);
            if (key.GetValue(ValueName) is null && Environment.ProcessPath is { } exe)
                key.SetValue(ValueName, $"\"{exe}\"");
        }
        catch { /* non-fatal */ }
    }

    public static bool IsEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) is not null;
        }
        catch { return false; }
    }

    public static void SetEnabled(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (key is null) return;
            if (enabled)
                key.SetValue(ValueName, $"\"{Environment.ProcessPath}\"");
            else
                key.DeleteValue(ValueName, throwOnMissingValue: false);
        }
        catch { /* non-fatal */ }
    }
}
