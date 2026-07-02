using System.Windows.Media;

namespace MyAgents.Ui;

/// <summary>Central colour palette (WPF brushes), referenced from XAML via x:Static and from VMs.</summary>
public static class Palette
{
    private static SolidColorBrush B(byte r, byte g, byte b, byte a = 255)
    {
        var br = new SolidColorBrush(Color.FromArgb(a, r, g, b));
        br.Freeze();
        return br;
    }

    // Glass tint laid over the acrylic backdrop (semi-transparent so blur shows).
    // Mostly opaque so the desktop never shows through during a resize (kills the
    // collapse "flash"); Mica still tints the rounded edges for a glassy feel.
    public static readonly SolidColorBrush GlassTint = B(26, 26, 30, 240);
    public static readonly SolidColorBrush HeaderTint = B(36, 36, 42, 245);
    public static readonly SolidColorBrush RowHover = B(255, 255, 255, 18);
    public static readonly SolidColorBrush Stroke = B(255, 255, 255, 28);
    public static readonly SolidColorBrush BarTrack = B(255, 255, 255, 30);

    public static readonly SolidColorBrush TextPrimary = B(245, 245, 247);
    public static readonly SolidColorBrush TextSecondary = B(176, 176, 184);
    public static readonly SolidColorBrush TextMuted = B(124, 124, 132);

    public static readonly SolidColorBrush Busy = B(217, 119, 87);     // Claude orange (default)
    public static readonly SolidColorBrush Permission = B(235, 190, 70);
    public static readonly SolidColorBrush Idle = B(120, 120, 128);

    // Per-provider identity colours (badge + accent + spinner when busy)
    public static readonly SolidColorBrush ProviderClaude = B(217, 119, 87);   // orange
    public static readonly SolidColorBrush ProviderCodex = B(64, 196, 180);    // teal
    public static readonly SolidColorBrush ProviderClaudeBg = B(217, 119, 87, 40);
    public static readonly SolidColorBrush ProviderCodexBg = B(64, 196, 180, 40);

    public static readonly SolidColorBrush UsageOk = B(217, 119, 87);
    public static readonly SolidColorBrush UsageWarn = B(232, 170, 80);
    public static readonly SolidColorBrush UsageHigh = B(226, 108, 108);
}
