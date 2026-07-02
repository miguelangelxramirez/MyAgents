using System.Runtime.InteropServices;
using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;

namespace MyAgents.Services;

/// <summary>
/// Brings the terminal hosting a session to the foreground.
///
/// Why not a title marker? Claude Code runs hooks WITHOUT a controlling terminal
/// (/dev/tty is unavailable), so a hook can't stamp the window title. Instead we
/// match the session's working directory against window titles (Windows Terminal
/// shows the cwd when CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1), and fall back to
/// simply surfacing the terminal window. See docs/state-schema.md.
/// </summary>
public static class WindowFocuser
{
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] private static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] private static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint a, uint b, bool f);
    [DllImport("user32.dll")] private static extern bool AllowSetForegroundWindow(uint pid);
    [DllImport("user32.dll")] private static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);

    private const int SW_RESTORE = 9;
    private const uint ASFW_ANY = unchecked((uint)-1);
    private const byte VK_MENU = 0x12;
    private const uint KEYEVENTF_KEYUP = 0x0002;

    // Window classes of the common terminals (used for the fallback).
    private static readonly string[] TerminalClasses =
        { "CASCADIA_HOSTING_WINDOW_CLASS", "ConsoleWindowClass", "Windows.UI.Core.CoreWindow" };

    public enum FocusResult { NotFound, Focused, FocusedApprox, FoundButFailed }

    private readonly record struct Win(IntPtr Handle, string Title, string Class);

    public static FocusResult FocusForSession(string cwd, string host, string? name = null, string? terminalHost = null)
    {
        var total = Stopwatch.StartNew();
        // The session NAME (Claude's task summary it puts in the tab title) is unique
        // per session → match it FIRST for precise focus; cwd is the ambiguous fallback.
        var candidates = new List<string>();
        if (!string.IsNullOrWhiteSpace(name) && name.Trim().Length >= 4) candidates.Add(name.Trim());
        candidates.AddRange(BuildCandidates(cwd));
        terminalHost = (terminalHost ?? "").Trim().ToLowerInvariant();
        Log.Write($"focus: name='{name}' cwd='{cwd}' host='{host}' terminalHost='{terminalHost}' candidates=[{string.Join(" | ", candidates)}]");

        // 0) Precise: select the exact Windows Terminal TAB via UI Automation.
        var uia = Stopwatch.StartNew();
        if (candidates.Count > 0 && TabFocuser.TrySelectTab(candidates, out var tabHwnd))
        {
            var focused = tabHwnd != IntPtr.Zero && Focus(tabHwnd);
            Log.Perf($"perf: focus total={total.ElapsedMilliseconds}ms uia={uia.ElapsedMilliseconds}ms result=Focused hwnd={tabHwnd:X} foreground={focused}", total.ElapsedMilliseconds, thresholdMs: 120);
            return FocusResult.Focused;
        }
        var uiaMs = uia.ElapsedMilliseconds;

        var enumSw = Stopwatch.StartNew();
        var wins = Enumerate();
        var enumMs = enumSw.ElapsedMilliseconds;

        if (terminalHost is "vscode" or "cursor")
        {
            var ide = TryFocusIdeWindow(wins, candidates, terminalHost);
            if (ide != FocusResult.NotFound)
            {
                Log.Perf($"perf: focus total={total.ElapsedMilliseconds}ms uia={uiaMs}ms enum={enumMs}ms result={ide} ide={terminalHost}", total.ElapsedMilliseconds, thresholdMs: 120);
                return ide;
            }
        }

        // 1) Exact-ish match: a window title containing the cwd (most specific first).
        foreach (var cand in candidates)
        {
            if (cand.Length < 3) continue;
            foreach (var w in wins)
                if (w.Title.Contains(cand, StringComparison.OrdinalIgnoreCase))
                {
                    Log.Write($"focus: matched '{cand}' in \"{w.Title}\" [{w.Class}]");
                    var ok = Focus(w.Handle);
                    Log.Perf($"perf: focus total={total.ElapsedMilliseconds}ms uia={uiaMs}ms enum={enumMs}ms result={(ok ? "Focused" : "FoundButFailed")}", total.ElapsedMilliseconds, thresholdMs: 120);
                    return ok ? FocusResult.Focused : FocusResult.FoundButFailed;
                }
        }

        // 2) Fallback: surface a terminal window so at least the terminal opens.
        foreach (var w in wins)
            if (TerminalClasses.Any(c => string.Equals(c, w.Class, StringComparison.OrdinalIgnoreCase)))
            {
                Log.Write($"focus: no cwd match; fallback to terminal window \"{w.Title}\" [{w.Class}]");
                var ok = Focus(w.Handle);
                Log.Perf($"perf: focus total={total.ElapsedMilliseconds}ms uia={uiaMs}ms enum={enumMs}ms result={(ok ? "FocusedApprox" : "FoundButFailed")}", total.ElapsedMilliseconds, thresholdMs: 120);
                return ok ? FocusResult.FocusedApprox : FocusResult.FoundButFailed;
            }

        // Nothing — dump everything so we can see what the real titles look like.
        Log.Write("focus: NO match and no terminal window. Visible windows:");
        foreach (var w in wins) Log.Write($"   [{w.Class}] \"{w.Title}\"");
        Log.Perf($"perf: focus total={total.ElapsedMilliseconds}ms uia={uiaMs}ms enum={enumMs}ms result=NotFound", total.ElapsedMilliseconds, thresholdMs: 120);
        return FocusResult.NotFound;
    }

    private static FocusResult TryFocusIdeWindow(List<Win> wins, IReadOnlyList<string> candidates, string terminalHost)
    {
        // Match only by the FULL product name in the title. A broad Contains("code")
        // fallback would also match Slack/Discord/any Electron app (all share the
        // Chrome_WidgetWin_1 class) and browser tabs mentioning "code" — focusing the
        // wrong window. Better to fall through to the generic terminal logic than guess.
        // (NB: tying focus to the session pid does NOT work for WSL-hosted sessions — the
        //  CLI pid lives in WSL's namespace and the IDE window is a separate Windows
        //  process; the two can't be related via GetWindowThreadProcessId.)
        string product = terminalHost == "cursor" ? "cursor" : "visual studio code";
        var ideWins = wins
            .Where(w => w.Class.Equals("Chrome_WidgetWin_1", StringComparison.OrdinalIgnoreCase)
                        && w.Title.Contains(product, StringComparison.OrdinalIgnoreCase))
            .ToList();

        foreach (var cand in candidates.Where(c => c.Length >= 3))
        {
            foreach (var w in ideWins)
                if (w.Title.Contains(cand, StringComparison.OrdinalIgnoreCase))
                {
                    Log.Write($"focus: matched IDE '{cand}' in \"{w.Title}\" [{w.Class}]");
                    return Focus(w.Handle) ? FocusResult.FocusedApprox : FocusResult.FoundButFailed;
                }
        }

        if (ideWins.Count == 1)
        {
            var w = ideWins[0];
            Log.Write($"focus: one IDE window for {terminalHost}; focusing \"{w.Title}\" [{w.Class}]");
            return Focus(w.Handle) ? FocusResult.FocusedApprox : FocusResult.FoundButFailed;
        }

        return FocusResult.NotFound;
    }

    /// <summary>Candidate substrings to look for in a window title, most specific first.</summary>
    private static List<string> BuildCandidates(string cwd)
    {
        var list = new List<string>();
        if (string.IsNullOrWhiteSpace(cwd)) return list;
        cwd = cwd.Replace('\\', '/').TrimEnd('/');
        list.Add(cwd);

        // ~/rel form used by WSL shells (PS1 replaces $HOME with ~)
        var tilde = Regex.Replace(cwd, "^/home/[^/]+", "~");
        tilde = Regex.Replace(tilde, "^/root$", "~");
        if (tilde != cwd) list.Add(tilde);

        var segs = cwd.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (segs.Length >= 2) list.Add(segs[^2] + "/" + segs[^1]);
        if (segs.Length >= 1) list.Add(segs[^1]);

        return list.Distinct().ToList();
    }

    private static List<Win> Enumerate()
    {
        var list = new List<Win>();
        var sb = new StringBuilder(512);
        EnumWindows((h, _) =>
        {
            if (!IsWindowVisible(h)) return true;
            int len = GetWindowTextLength(h);
            if (len <= 0) return true;
            if (sb.Capacity < len + 1) sb.Capacity = len + 1;
            sb.Clear(); GetWindowText(h, sb, sb.Capacity);
            var title = sb.ToString();
            sb.Clear(); GetClassName(h, sb, sb.Capacity);
            list.Add(new Win(h, title, sb.ToString()));
            return true;
        }, IntPtr.Zero);
        return list;
    }

    private static bool Focus(IntPtr hWnd)
    {
        if (GetForegroundWindow() == hWnd) return true;
        uint fore = GetWindowThreadProcessId(GetForegroundWindow(), out _);
        uint me = GetCurrentThreadId();
        bool attached = false;
        try
        {
            AllowSetForegroundWindow(ASFW_ANY);
            if (fore != 0 && fore != me) attached = AttachThreadInput(me, fore, true);
            if (IsIconic(hWnd)) ShowWindow(hWnd, SW_RESTORE);
            BringWindowToTop(hWnd);
            if (!SetForegroundWindow(hWnd))
            {
                keybd_event(VK_MENU, 0, 0, UIntPtr.Zero);
                keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
                SetForegroundWindow(hWnd);
            }
        }
        finally { if (attached) AttachThreadInput(me, fore, false); }
        return GetForegroundWindow() == hWnd;
    }
}
