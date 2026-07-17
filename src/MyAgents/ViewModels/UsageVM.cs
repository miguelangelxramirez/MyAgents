using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows.Media;
using MyAgents.Models;
using MyAgents.Ui;

namespace MyAgents.ViewModels;

/// <summary>Bindable view of the 5h / 7d usage bars.</summary>
public sealed class UsageVM : INotifyPropertyChanged
{
    private readonly Brush _barBrush;
    private bool _hasData;
    private string _statusText = "Usage: loading…";
    private double _sessionPercent, _weeklyPercent;
    private string _sessionText = "", _weeklyText = "";
    private Brush _sessionBrush, _weeklyBrush;
    private string _staleNote = "";

    /// <summary>Bars are coloured by PROVIDER (Claude orange / Codex teal), not by %,
    /// so the two are easy to tell apart at a glance.</summary>
    public UsageVM(Brush barBrush)
    {
        _barBrush = barBrush;
        _sessionBrush = barBrush;
        _weeklyBrush = barBrush;
    }

    public bool HasData { get => _hasData; private set => Set(ref _hasData, value); }
    public string StatusText { get => _statusText; private set => Set(ref _statusText, value); }
    public double SessionPercent { get => _sessionPercent; private set => Set(ref _sessionPercent, value); }
    public double WeeklyPercent { get => _weeklyPercent; private set => Set(ref _weeklyPercent, value); }
    public string SessionText { get => _sessionText; private set => Set(ref _sessionText, value); }
    public string WeeklyText { get => _weeklyText; private set => Set(ref _weeklyText, value); }
    public Brush SessionBrush { get => _sessionBrush; private set => Set(ref _sessionBrush, value); }
    public Brush WeeklyBrush { get => _weeklyBrush; private set => Set(ref _weeklyBrush, value); }
    /// <summary>One-line note under the group when the capture is old (idle session); "" when fresh.</summary>
    public string StaleNote { get => _staleNote; private set => Set(ref _staleNote, value); }

    public void Update(UsageInfo u)
    {
        if (u.Status != UsageStatus.Ok)
        {
            // Disabled is an explicit user choice → clear the bars. Any other
            // failure (rate-limit 429, transient network, expired token) is
            // treated as transient: KEEP the last good bars instead of flickering
            // them away, unless we never had data.
            if (u.Status != UsageStatus.Disabled && HasData) return;

            HasData = false;
            StaleNote = "";
            StatusText = u.Status switch
            {
                UsageStatus.Disabled => "Usage off — enable in the ⚙ menu",
                UsageStatus.NoCredentials => "Sign in to Claude Code to show usage",
                UsageStatus.AuthNeeded => "Token expired — re-login to Claude Code",
                UsageStatus.Unknown => "Usage: loading…",
                _ => "Usage unavailable",
            };
            return;
        }

        HasData = true;
        // Trust the fresh capture (like claude-status-bar): always show the % + when it resets.
        // (The statusline rewrites usage.json every render, so reset_at is current.)
        SessionPercent = Math.Clamp(u.SessionPercent, 0, 100);
        WeeklyPercent = Math.Clamp(u.WeeklyPercent, 0, 100);
        // If the capture is OLD (idle Claude session: statusline stops re-rendering, so usage.json
        // freezes) flag it clearly with its age instead of pretending it's live. RPC/endpoint
        // sources set CapturedAtUnix=0 (always live) so they never show this.
        // ALWAYS show the reset countdown on each bar. If the capture is old (idle Claude session:
        // the statusline stops re-rendering, so usage.json freezes), keep the countdown AND grey the
        // bars, and put the age on its OWN one-line note below the group — so neither text shrinks.
        long ageMin = u.CapturedAtUnix > 0 ? (DateTimeOffset.UtcNow.ToUnixTimeSeconds() - u.CapturedAtUnix) / 60 : 0;
        bool captureStale = ageMin >= 30;   // Claude idle session: usage.json stops refreshing
        // A window is ALSO stale when its reset time has already PASSED — a snapshot the live source
        // (Codex RPC) couldn't refresh (e.g. WSL exec down), so the % is old and the countdown reads
        // "now". Grey it and say so, instead of presenting a stale reading as if it were live.
        bool sStale = captureStale || u.SessionStale;
        bool wStale = captureStale || u.WeeklyStale;
        SessionText = $"{SessionPercent:0}%   ·   {ResetText(u.SessionResetsAt)}";
        WeeklyText = $"{WeeklyPercent:0}%   ·   {ResetText(u.WeeklyResetsAt)}";
        SessionBrush = sStale ? Palette.TextMuted : _barBrush;
        WeeklyBrush = wStale ? Palette.TextMuted : _barBrush;
        StaleNote = captureStale ? $"last updated {ageMin}m ago (session idle)"
                  : (sStale || wStale) ? "usage may be out of date — waiting for a fresh reading"
                  : "";
    }

    private static string ResetText(DateTimeOffset? reset)
    {
        if (reset is null) return "—";
        var left = reset.Value - DateTimeOffset.Now;
        if (left <= TimeSpan.Zero) return "now";
        if (left.TotalDays >= 1) return $"resets {(int)left.TotalDays}d {left.Hours}h";
        if (left.TotalHours >= 1) return $"resets {(int)left.TotalHours}h {left.Minutes}m";
        return $"resets {left.Minutes}m";
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void Set<T>(ref T field, T value, [CallerMemberName] string? n = null)
    {
        if (!Equals(field, value)) { field = value; PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n)); }
    }
}
