namespace MyAgents.Services;

/// <summary>
/// Tiny logger. Verbose logs are off unless CCAPP_DEBUG=1; slow perf events
/// are still recorded so UI stalls can be diagnosed in normal builds.
/// </summary>
public static class Log
{
    private static readonly bool Enabled =
        Environment.GetEnvironmentVariable("CCAPP_DEBUG") == "1";

    private static readonly string Path =
        System.IO.Path.Combine(System.IO.Path.GetTempPath(), "myagents.log");

    public static void Write(string msg)
    {
        if (!Enabled) return;
        Append(msg);
    }

    public static void Perf(string msg, long elapsedMs, long thresholdMs = 250)
    {
        if (!Enabled && elapsedMs < thresholdMs) return;
        Append(msg);
    }

    private static void Append(string msg)
    {
        try { System.IO.File.AppendAllText(Path, $"{DateTime.Now:HH:mm:ss} {msg}{Environment.NewLine}"); }
        catch { /* logging must never break the app */ }
    }
}
