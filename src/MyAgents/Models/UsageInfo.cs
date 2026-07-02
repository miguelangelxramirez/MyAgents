namespace MyAgents.Models;

public enum UsageStatus { Unknown, Ok, NoCredentials, AuthNeeded, Error, Disabled }

/// <summary>Claude Code usage for the current 5-hour and 7-day windows.</summary>
public sealed class UsageInfo
{
    public UsageStatus Status { get; set; } = UsageStatus.Unknown;

    public double SessionPercent { get; set; }      // 0..100, the 5h window
    public DateTimeOffset? SessionResetsAt { get; set; }
    public bool SessionStale { get; set; }           // reset_at already passed → value predates the window roll-over

    public double WeeklyPercent { get; set; }        // 0..100, the 7d window
    public DateTimeOffset? WeeklyResetsAt { get; set; }
    public bool WeeklyStale { get; set; }

    /// <summary>When the reading was captured (unix s). 0 = live source (RPC/endpoint). For the
    /// file-based Claude capture, lets the UI flag a stale (idle-session, not-refreshing) value.</summary>
    public long CapturedAtUnix { get; set; }

    public bool HasData => Status == UsageStatus.Ok;
}
