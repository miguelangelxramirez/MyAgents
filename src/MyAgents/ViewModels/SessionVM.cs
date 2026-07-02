using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows.Media;
using MyAgents.Models;
using MyAgents.Ui;

namespace MyAgents.ViewModels;

/// <summary>Bindable view of one session row. Updated in place so spinner animations persist.</summary>
public sealed class SessionVM : INotifyPropertyChanged
{
    public string SessionId { get; }
    public string Cwd { get; private set; } = "";
    public string Host { get; private set; } = "";
    public string TerminalHost { get; private set; } = "";
    public string FocusName { get; private set; } = "";   // Claude's unique session title (for precise focus)

    private string _title = "";
    private string _folder = "";
    private string _action = "";
    private string _providerLabel = "Claude";
    private Brush _providerBrush = Palette.ProviderClaude;
    private Brush _providerBg = Palette.ProviderClaudeBg;
    private Brush _accent = Palette.Idle;
    private Brush _actionBrush = Palette.TextSecondary;
    private bool _isBusy, _isPermission, _pending;

    public SessionVM(SessionState s) { SessionId = s.SessionId; Update(s); }

    // Line 1 / 2 / 3
    public string Title { get => _title; set => Set(ref _title, value); }
    public string Folder { get => _folder; set => Set(ref _folder, value); }
    public string Action { get => _action; set => Set(ref _action, value); }

    public string ProviderLabel { get => _providerLabel; set => Set(ref _providerLabel, value); }
    public Brush ProviderBrush { get => _providerBrush; set => Set(ref _providerBrush, value); }
    public Brush ProviderBg { get => _providerBg; set => Set(ref _providerBg, value); }
    public Brush Accent { get => _accent; set => Set(ref _accent, value); }
    public Brush ActionBrush { get => _actionBrush; set => Set(ref _actionBrush, value); }

    public bool IsBusy { get => _isBusy; set => Set(ref _isBusy, value); }
    public bool IsPermission { get => _isPermission; set => Set(ref _isPermission, value); }
    public bool IsIdle => !_isBusy && !_isPermission;

    /// <summary>A finished session you haven't opened yet → unread marker.</summary>
    public bool Pending { get => _pending; set => Set(ref _pending, value); }
    public void MarkSeen() => Pending = false;

    public void Update(SessionState s)
    {
        bool wasActive = _isBusy || _isPermission;

        Cwd = s.Cwd;
        Host = s.Host;
        TerminalHost = s.TerminalHost;
        bool isCodex = string.Equals(s.Provider, "codex", StringComparison.OrdinalIgnoreCase);
        ProviderLabel = isCodex ? "Codex" : "Claude";
        ProviderBrush = isCodex ? Palette.ProviderCodex : Palette.ProviderClaude;
        ProviderBg = isCodex ? Palette.ProviderCodexBg : Palette.ProviderClaudeBg;

        var project = string.IsNullOrEmpty(s.Project) ? "" : s.Project;
        var name = (s.Name ?? "").Trim();
        FocusName = name;
        // Line 1 = session name; line 2 = folder. Without a name yet, fall back
        // to the folder and show only a short id below so the UI does not repeat
        // the same folder twice while still distinguishing same-folder sessions.
        bool synthetic = SessionId.StartsWith("proc:", StringComparison.Ordinal);
        string shortId = synthetic || SessionId.Length < 4 ? "" : SessionId[..Math.Min(8, SessionId.Length)];
        Title = name.Length > 0 ? name : (project.Length > 0 ? project : "(new session)");
        Folder = name.Length > 0
            ? (string.Equals(name, project, StringComparison.OrdinalIgnoreCase) ? "" : project)
            : (shortId.Length > 0 ? $"id {shortId}" : "");

        // Out-of-tokens / crash safety: when Claude is rate-limited (or killed) mid-turn it
        // stops WITHOUT firing Stop, so the last "thinking" state would otherwise stick for
        // up to an hour and show a fake "Thinking…". If a thinking turn goes silent (no fresh
        // hook event) past a short window, treat it as idle. Tools get a long leash because a
        // single command (build, test) can legitimately run for minutes.
        // "thinking" with no progress = stalled (interrupt / out-of-tokens fire no Stop hook).
        // Prefer the transcript mtime (advances while Claude streams, frozen when idle) over a
        // wall-clock timer; fall back to the hook timestamp when we couldn't stat the transcript.
        // TRUST THE HOOKS (like claude-status-bar) — no timer heuristic. A timer that flips
        // "thinking" to idle is what caused the false "idle" while the session was actually
        // working. State is exactly what the last hook wrote; process-liveness handles close.
        bool busy = s.IsBusy;

        IsBusy = busy;
        IsPermission = s.NeedsAttention;
        OnPropertyChanged(nameof(IsIdle));
        Accent = s.NeedsAttention ? Palette.Permission : busy ? ProviderBrush : Palette.Idle;
        // Colour the state line too: provider colour while busy (Thinking…/tool), amber for a
        // permission prompt, muted grey when idle.
        ActionBrush = s.NeedsAttention ? Palette.Permission : busy ? ProviderBrush : Palette.TextSecondary;

        var action = s.NeedsAttention ? "Awaiting your permission"
                   : string.IsNullOrEmpty(s.Label) ? "Ready" : s.Label;
        if (busy && s.ElapsedSeconds > 0) action += "   ·   " + FormatElapsed(s.ElapsedSeconds);
        Action = action;

        // Busy/permission → idle transition = the turn finished; flag as pending
        // (cleared when the user clicks/opens the row).
        if (wasActive && IsIdle) Pending = true;
    }

    private static string FormatElapsed(long sec)
    {
        if (sec < 60) return sec + "s";
        var m = sec / 60; var s = sec % 60;
        return m < 60 ? $"{m}m {s}s" : $"{m / 60}h {m % 60}m";
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged([CallerMemberName] string? n = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
    private void Set<T>(ref T field, T value, [CallerMemberName] string? n = null)
    {
        if (!Equals(field, value)) { field = value; OnPropertyChanged(n); }
    }
}
