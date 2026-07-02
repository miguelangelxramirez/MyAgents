using System.Diagnostics;
using System.Text;
using MyAgents.Models;

namespace MyAgents.Services;

/// <summary>
/// Discovers OPEN sessions by the most robust signal there is: a live claude/codex
/// process. Survives reboots and idle sessions (a session is open iff its CLI
/// process is running), and detects close (process gone) without relying on
/// SessionEnd or transcript timing. Each live process gives its provider + cwd.
/// </summary>
public sealed class ProcessScanner
{
    public readonly record struct Proc(long Pid, string Provider, string Cwd, string Origin);

    private List<string> _distros = new();

    public ProcessScanner() => RefreshRoots();
    public void RefreshRoots() => _distros = RunningDistros();

    /// <summary>Live claude/codex processes across all running WSL distros (+ Windows).</summary>
    public List<Proc> Scan()
    {
        var list = new List<Proc>();
        foreach (var distro in _distros)
            ScanWsl(distro, list);
        ScanWindows(list);
        return list;
    }

    private static void ScanWsl(string distro, List<Proc> into)
    {
        // For each claude/codex process, print "<comm>|<cwd>".
        // Passed via STDIN (sh -s), NOT as an argument — wsl.exe mangles complex
        // quoted args ($(), quotes) which broke this with a dash syntax error.
        // Union of: comm==claude/codex AND node processes whose cmdline is the CLI
        // (covers Claude/Codex running as `node`). Excludes our own hook scripts and
        // mcp servers. Classify by cmdline. Sent via STDIN (sh -s) — wsl mangles args.
        const string sh =
            "PATH=/usr/bin:/bin:$PATH\n" +
            "{ pgrep -x claude; pgrep -x codex; pgrep -x node; } | sort -un | while read p; do\n" +
            "  [ -d /proc/$p ] || continue\n" +
            "  cmd=$(tr '\\0' ' ' < /proc/$p/cmdline 2>/dev/null)\n" +
            "  case \"$cmd\" in *statusbar*|*update.js*|*lifecycle.js*|*mcp*) continue ;; esac\n" +
            "  case \"$cmd\" in *codex*) prov=codex ;; *claude*) prov=claude ;; *) continue ;; esac\n" +
            "  echo \"$p|$prov|$(readlink /proc/$p/cwd 2>/dev/null)\"\n" +
            "done\n";
        try
        {
            var psi = new ProcessStartInfo("wsl.exe")
            { RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true, StandardOutputEncoding = Encoding.UTF8, StandardInputEncoding = new UTF8Encoding(false) };
            foreach (var a in new[] { "-d", distro, "--", "sh", "-s" }) psi.ArgumentList.Add(a);
            using var p = Process.Start(psi);
            if (p is null) return;
            p.StandardInput.Write(sh);
            p.StandardInput.Close();
            var outp = p.StandardOutput.ReadToEnd();
            var err = p.StandardError.ReadToEnd();
            if (!p.WaitForExit(4000)) { try { p.Kill(); } catch { } Log.Write($"proc:{distro} timeout"); return; }
            var e = err.Replace("\n", ";").Trim();
            Log.Write($"proc:{distro} out='{outp.Replace("\n", ";").Trim()}' err='{e[..Math.Min(e.Length, 100)]}'");
            // Detect the crashed-WSL-service signature so the UI can offer "Restart WSL".
            if (e.Contains("E_UNEXPECTED", StringComparison.OrdinalIgnoreCase) || e.Contains("catastr", StringComparison.OrdinalIgnoreCase))
                Wsl.ExecBroken = true;
            else if (outp.Trim().Length > 0)
                Wsl.ExecBroken = false;
            foreach (var raw in outp.Split('\n'))
            {
                var parts = raw.Replace("\r", "").Trim().Split('|');
                if (parts.Length < 3) continue;
                if (!long.TryParse(parts[0].Trim(), out var pid)) continue;
                var comm = parts[1].Trim().ToLowerInvariant();
                var cwd = parts[2].Trim();
                if (cwd.Length == 0) continue;
                var provider = comm.Contains("codex") ? "codex" : comm.Contains("claude") ? "claude" : null;
                if (provider is null) continue;
                into.Add(new Proc(pid, provider, cwd, distro));
            }
        }
        catch { }
    }

    private static void ScanWindows(List<Proc> into)
    {
        // Best-effort: native Windows claude/codex processes (cwd not readily available).
        foreach (var name in new[] { "claude", "codex" })
        {
            try
            {
                foreach (var p in Process.GetProcessesByName(name))
                    using (p) into.Add(new Proc(p.Id, name, "", "Windows"));
            }
            catch { }
        }
    }

    /// <summary>
    /// Key used to match a session to a live process: provider + normalized cwd.
    /// Paths under /mnt/<drive> are Windows paths exposed through WSL, so they are
    /// case-insensitive; without this, /mnt/c/Users and /mnt/c/users look like two
    /// sessions and the fallback/liveness layer creates duplicate rows.
    /// </summary>
    public static string Key(string provider, string cwd) => provider.ToLowerInvariant() + "|" + NormalizeCwd(cwd);

    private static string NormalizeCwd(string cwd)
    {
        if (string.IsNullOrWhiteSpace(cwd)) return "";
        var p = cwd.Replace('\\', '/').Trim().TrimEnd('/');
        while (p.Contains("//", StringComparison.Ordinal)) p = p.Replace("//", "/");

        if (p.Length >= 3 && p[1] == ':' && p[2] == '/')
            p = "/mnt/" + char.ToLowerInvariant(p[0]) + p[2..];

        if (p.StartsWith("/mnt/", StringComparison.OrdinalIgnoreCase)
            && p.Length >= 7
            && char.IsLetter(p[5])
            && p[6] == '/')
            return p.ToLowerInvariant();

        return p;
    }

    private static List<string> RunningDistros()
    {
        var list = new List<string>();
        try
        {
            var psi = new ProcessStartInfo("wsl.exe", "-l --running -q")
            { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true, StandardOutputEncoding = Encoding.Unicode };
            using var p = Process.Start(psi);
            if (p is null) return list;
            var outp = p.StandardOutput.ReadToEnd(); p.WaitForExit(4000);
            foreach (var raw in outp.Split('\n')) { var n = raw.Replace("\r", "").Replace("\0", "").Trim(); if (n.Length > 0) list.Add(n); }
        }
        catch { }
        Log.Write($"proc: running distros=[{string.Join(",", list)}]");
        return list;
    }
}
