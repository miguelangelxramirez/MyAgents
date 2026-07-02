using System.Diagnostics;
using System.Text;

namespace MyAgents.Services;

/// <summary>
/// Checks whether a session's owning CLI process is still alive — the robust way
/// to know a session closed, especially Codex (which has no SessionEnd hook).
/// </summary>
public static class ProcessLiveness
{
    /// <summary>Subset of <paramref name="pids"/> still alive inside a WSL distro,
    /// or NULL if the check failed (caller must not reap on a failed check).</summary>
    public static HashSet<long>? AliveInWsl(string distro, IReadOnlyCollection<long> pids)
    {
        if (pids.Count == 0) return new HashSet<long>();
        try
        {
            var list = string.Join(" ", pids);
            var psi = new ProcessStartInfo("wsl.exe")
            { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true, StandardOutputEncoding = Encoding.UTF8 };
            foreach (var a in new[] { "-d", distro, "--", "sh", "-c", $"for p in {list}; do [ -e /proc/$p ] && echo $p; done" })
                psi.ArgumentList.Add(a);
            using var p = Process.Start(psi);
            if (p is null) return null;
            var outp = p.StandardOutput.ReadToEnd();
            if (!p.WaitForExit(4000)) { try { p.Kill(); } catch { } return null; }
            var alive = new HashSet<long>();
            foreach (var line in outp.Split('\n'))
                if (long.TryParse(line.Trim(), out var v)) alive.Add(v);
            return alive;
        }
        catch { return null; }
    }

    public static bool AliveOnWindows(long pid)
    {
        try { using var p = Process.GetProcessById((int)pid); return !p.HasExited; }
        catch { return false; }
    }
}
