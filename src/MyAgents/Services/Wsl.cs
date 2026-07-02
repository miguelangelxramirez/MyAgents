using System.Diagnostics;
using System.Text;

namespace MyAgents.Services;

/// <summary>
/// Shared, hang-proof, cached list of running WSL distros. `wsl.exe -l` can block forever
/// on ReadToEnd when the WSL service is in E_UNEXPECTED, so we read with a hard timeout and
/// kill the process. The last non-empty result is cached and SHARED across all services —
/// so once any scan discovers the distro (e.g. the session scanner), usage/codex reads can
/// reuse it via UNC even while wsl.exe command-exec is broken.
/// </summary>
public static class Wsl
{
    private static volatile List<string> _cache = new();

    /// <summary>True when WSL command-exec is failing (E_UNEXPECTED) — the tell-tale that the
    /// WSL service crashed (usually after resume) and needs `wsl --shutdown`. Set by the
    /// process scan (which runs a WSL command every poll), so we KNOW it's the case.</summary>
    public static volatile bool ExecBroken;

    public static IReadOnlyList<string> Distros()
    {
        try
        {
            var psi = new ProcessStartInfo("wsl.exe", "-l --running -q")
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
                StandardOutputEncoding = Encoding.Unicode,
            };
            using var p = Process.Start(psi);
            if (p is not null)
            {
                var readTask = p.StandardOutput.ReadToEndAsync();
                if (readTask.Wait(2500))
                {
                    try { p.WaitForExit(500); } catch { }
                    var list = new List<string>();
                    foreach (var raw in readTask.Result.Split('\n'))
                    {
                        var n = raw.Replace("\r", "").Replace("\0", "").Trim();
                        if (n.Length > 0) list.Add(n);
                    }
                    if (list.Count > 0) { _cache = list; return list; }
                }
                else { try { p.Kill(true); } catch { } }   // hung → give up, use the shared cache
            }
        }
        catch { }
        return _cache;   // wsl.exe hung/failed → reuse the last known distros (UNC reads still work)
    }
}
