using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using MyAgents.Models;

namespace MyAgents.Services;

public static class DiagnosticsService
{
    public static string Export(AppSettings settings, IReadOnlyList<SessionState> sessions)
    {
        var ts = DateTime.Now.ToString("yyyyMMdd-HHmmss");
        var file = Path.Combine(Path.GetTempPath(), $"myagents-diagnostics-{ts}.txt");
        var sb = new StringBuilder();

        sb.AppendLine("MyAgents diagnostics");
        sb.AppendLine("==========================");
        sb.AppendLine("PRIVACY: no tokens/credentials are included, but this file DOES contain local");
        sb.AppendLine("paths, project/folder names, and truncated session titles (your prompts). Review");
        sb.AppendLine("it before pasting into a public issue.");
        sb.AppendLine();
        sb.AppendLine($"Time: {DateTimeOffset.Now:O}");
        sb.AppendLine($"Version: {Assembly.GetExecutingAssembly().GetName().Version}");
        sb.AppendLine($"OS: {Environment.OSVersion}");
        sb.AppendLine($"Process: {Environment.ProcessId}");
        sb.AppendLine();

        sb.AppendLine("Settings");
        sb.AppendLine("--------");
        sb.AppendLine($"Corner: {settings.Corner}");
        sb.AppendLine($"WidgetVisible: {settings.WidgetVisible}");
        sb.AppendLine($"Collapsed: {settings.Collapsed}");
        sb.AppendLine($"CodexEnabled: {settings.CodexEnabled}");
        sb.AppendLine($"UsageEnabled: {settings.UsageEnabled}");
        sb.AppendLine($"NotificationsEnabled: {settings.NotificationsEnabled}");
        sb.AppendLine();

        sb.AppendLine("Sessions shown by app");
        sb.AppendLine("---------------------");
        if (sessions.Count == 0) sb.AppendLine("(none)");
        foreach (var s in sessions)
        {
            sb.AppendLine($"- {s.Provider} | {s.State} | pid={s.Pid} | id={Short(s.SessionId)}");
            sb.AppendLine($"  name={OneLine(s.Name)}");
            sb.AppendLine($"  project={s.Project}");
            sb.AppendLine($"  cwd={s.Cwd}");
            sb.AppendLine($"  host={s.Host} terminalHost={s.TerminalHost}");
            sb.AppendLine($"  source={s.SourcePath}");
        }
        sb.AppendLine();

        sb.AppendLine("Live CLI processes");
        sb.AppendLine("------------------");
        try
        {
            var procs = new ProcessScanner();
            var live = procs.Scan();
            if (live.Count == 0) sb.AppendLine("(none or unavailable)");
            foreach (var p in live)
                sb.AppendLine($"- {p.Provider} | pid={p.Pid} | origin={p.Origin} | cwd={p.Cwd}");
        }
        catch (Exception ex) { sb.AppendLine("process scan failed: " + ex.Message); }
        sb.AppendLine();

        sb.AppendLine("Recent app log");
        sb.AppendLine("--------------");
        foreach (var line in Tail(LogPath(), 160))
            sb.AppendLine(line);

        File.WriteAllText(file, sb.ToString(), Encoding.UTF8);
        return file;
    }

    private static string LogPath() => Path.Combine(Path.GetTempPath(), "myagents.log");

    private static List<string> Tail(string path, int maxLines)
    {
        var lines = new List<string>();
        try
        {
            if (!File.Exists(path)) return lines;
            var q = new Queue<string>(maxLines);
            foreach (var line in File.ReadLines(path))
            {
                if (q.Count == maxLines) q.Dequeue();
                q.Enqueue(line);
            }
            lines.AddRange(q);
        }
        catch { }
        return lines;
    }

    private static string Short(string s) => string.IsNullOrEmpty(s) ? "" : s[..Math.Min(12, s.Length)];
    private static string OneLine(string s)
    {
        var t = (s ?? "").Replace("\r", " ").Replace("\n", " ").Trim();
        // Session "name" can be the user's first prompt — truncate so the diagnostics
        // file never carries a full prompt into a shared/public report.
        return t.Length <= 48 ? t : t[..48] + "…";
    }
}
