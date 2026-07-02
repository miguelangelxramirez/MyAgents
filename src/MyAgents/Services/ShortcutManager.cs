using System.IO;
using System.Runtime.Versioning;

namespace MyAgents.Services;

/// <summary>Keeps a Start-menu shortcut for the app so a user can reopen it after closing it
/// (winget's "portable" install and a bare Releases .exe create no Start-menu entry). With the
/// shortcut present, typing "MyAgents" in the Windows search opens it. Best-effort — never fatal.</summary>
[SupportedOSPlatform("windows")]
public static class ShortcutManager
{
    private static string LinkPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.Programs), "MyAgents.lnk");

    /// <summary>Create (or refresh) the Start-menu shortcut pointing at the current exe. Rewritten
    /// on every startup so it self-heals when the exe moves (e.g. a winget upgrade to a new path).
    /// Call once at startup.</summary>
    public static void EnsureStartMenuShortcut()
    {
        try
        {
            if (Environment.ProcessPath is not { } exe) return;
            var type = Type.GetTypeFromProgID("WScript.Shell");
            if (type is null) return;
            dynamic? shell = Activator.CreateInstance(type);
            if (shell is null) return;
            dynamic link = shell.CreateShortcut(LinkPath);
            link.TargetPath = exe;
            link.WorkingDirectory = Path.GetDirectoryName(exe) ?? "";
            link.IconLocation = $"{exe},0";
            link.Description = "MyAgents — watch all your Claude Code and Codex sessions";
            link.Save();
        }
        catch { /* non-fatal: a missing shortcut only makes reopening less convenient */ }
    }

    /// <summary>Remove the Start-menu shortcut (called from Uninstall hooks). Best-effort.</summary>
    public static void RemoveStartMenuShortcut()
    {
        try { if (File.Exists(LinkPath)) File.Delete(LinkPath); }
        catch { /* non-fatal */ }
    }
}
