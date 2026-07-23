using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using MyAgents.Models;
using MyAgents.Services;
using MyAgents.ViewModels;

namespace MyAgents.Ui;

public partial class WidgetWindow : Window, INotifyPropertyChanged
{
    private readonly AppSettings _settings;

    public ObservableCollection<SessionVM> Sessions { get; } = new();
    public UsageVM Usage { get; } = new(Palette.ProviderClaude);
    public UsageVM CodexUsage { get; } = new(Palette.ProviderCodex);

    private string _headerText = "MyAgents";
    public string HeaderText { get => _headerText; private set => Set(ref _headerText, value); }

    private bool _isEmpty = true;
    public bool IsEmpty { get => _isEmpty; private set => Set(ref _isEmpty, value); }

    private bool _updateAvailable;
    public bool UpdateAvailable { get => _updateAvailable; private set => Set(ref _updateAvailable, value); }
    private string _updateText = "";
    public string UpdateText { get => _updateText; private set => Set(ref _updateText, value); }
    private string _updateUrl = "";

    public event Action? CloseRequested;
    public event Action? SettingsRequested;

    private const double EdgeMargin = 4;

    // --- Win32: force real "always on top" Z-order. WPF's Topmost property sets the style but,
    // when the app shows the window from a BACKGROUND process (at boot / after resume), Windows
    // does NOT actually re-order it to the front — it keeps the topmost flag yet leaves the window
    // BEHIND the foreground app (measured: topmost=True but sitting behind everything). SetWindowPos
    // with HWND_TOPMOST forces the genuine Z-order reinsert, works from the background (no foreground
    // rights needed) and never steals focus (SWP_NOACTIVATE). See EnsureTopmost().
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int x, int y, int cx, int cy, uint flags);
    private static readonly IntPtr HWND_TOPMOST = new(-1);
    private const uint SWP_NOSIZE = 0x0001, SWP_NOMOVE = 0x0002, SWP_NOACTIVATE = 0x0010;

    public WidgetWindow(AppSettings settings)
    {
        _settings = settings;
        InitializeComponent();
        DataContext = this;
        ApplyLayout();
        ApplyCollapsed();
        // The window auto-sizes to content (SizeToContent). Re-pin to the chosen
        // corner whenever its height changes so bottom corners grow upward.
        SizeChanged += (_, _) => ApplyAnchor();
    }

    // ---- Data updates ----

    private const int MissesToDrop = 3; // a session must be absent this many polls before we remove it
    private readonly Dictionary<string, int> _miss = new(StringComparer.Ordinal);

    public void UpdateSessions(List<SessionState> list)
    {
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var s in list)
        {
            ids.Add(s.SessionId);
            _miss[s.SessionId] = 0; // present → reset the absence counter
            var vm = Sessions.FirstOrDefault(v => v.SessionId == s.SessionId);
            if (vm is null) Sessions.Add(new SessionVM(s));
            else vm.Update(s);
        }
        // Debounced removal: only drop a row after it's been missing several polls
        // in a row. Kills flicker from transient read/rename/transcript races.
        for (int i = Sessions.Count - 1; i >= 0; i--)
        {
            var id = Sessions[i].SessionId;
            if (ids.Contains(id)) continue;
            int n = _miss.GetValueOrDefault(id) + 1;
            _miss[id] = n;
            if (n >= MissesToDrop) { Sessions.RemoveAt(i); _miss.Remove(id); }
        }

        int perm = list.Count(x => x.NeedsAttention);
        int busy = list.Count(x => x.IsBusy);
        HeaderText = perm > 0
            ? $"MyAgents      ⚠ {perm} need you"
            : $"MyAgents      {list.Count} open · {busy} working";
        // Only when we KNOW WSL command-exec crashed (E_UNEXPECTED) — tell the user how to fix it.
        if (MyAgents.Services.Wsl.ExecBroken)
            HeaderText = "⚠ WSL stuck — ⚙ menu → Restart WSL";
        IsEmpty = list.Count == 0;
    }

    public void SetUsage(UsageInfo u) => Usage.Update(u);
    public void SetCodexUsage(UsageInfo u) => CodexUsage.Update(u);

    /// <summary>Show a small, discreet "update available" link in the header. Clicking it opens the
    /// Releases page in the browser — the app never downloads or replaces itself.</summary>
    public void SetUpdateAvailable(string version, string url)
    {
        _updateUrl = url;
        UpdateText = $"update {version} ↗";
        UpdateAvailable = true;
    }

    private void Update_Click(object sender, MouseButtonEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(_updateUrl)) return;
        try { Process.Start(new ProcessStartInfo(_updateUrl) { UseShellExecute = true }); } catch { }
    }

    // ---- Interaction ----

    private void Header_Drag(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left) return;
        double l = Left, t = Top;
        DragMove();              // returns when the user releases the mouse
        bool moved = Math.Abs(Left - l) > 3 || Math.Abs(Top - t) > 3;
        if (moved) { SnapToNearestCorner(); return; }   // it was a drag → re-snap
        // It was a CLICK (no drag) on the bar itself → toggle collapse BOTH ways, so you
        // don't have to aim for the little arrow (open→close and closed→open). The buttons
        // in the header handle their own clicks, so this only fires on the empty bar area.
        _settings.Collapsed = !_settings.Collapsed;
        _settings.Save();
        ApplyCollapsed();
    }

    private void Collapse_Click(object sender, RoutedEventArgs e)
    {
        _settings.Collapsed = !_settings.Collapsed;
        _settings.Save();
        ApplyCollapsed();
    }

    private void ApplyCollapsed()
    {
        bool c = _settings.Collapsed;
        BodyArea.Visibility = c ? Visibility.Collapsed : Visibility.Visible;
        UsageArea.Visibility = c ? Visibility.Collapsed : Visibility.Visible;
        CollapseBtn.Content = CollapseGlyph();
    }

    /// <summary>Arrow points the way the content moves: bottom-dock → ▾ collapses
    /// (folds down to the bar), ▴ expands (rises up); top-dock is mirrored.</summary>
    private string CollapseGlyph()
    {
        bool bottom = _settings.Corner.StartsWith("bottom", StringComparison.OrdinalIgnoreCase);
        bool c = _settings.Collapsed;
        return bottom ? (c ? "▴" : "▾") : (c ? "▾" : "▴");
    }

    private void Close_Click(object sender, RoutedEventArgs e) => CloseRequested?.Invoke();

    private void Settings_Click(object sender, RoutedEventArgs e) => SettingsRequested?.Invoke();

    private async void Row_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement fe && fe.DataContext is SessionVM vm)
        {
            vm.MarkSeen();   // opening it clears the "pending" dot
            var sw = Stopwatch.StartNew();
            var cwd = vm.Cwd;
            var host = vm.Host;
            var name = vm.FocusName;
            var terminalHost = vm.TerminalHost;
            var r = await Task.Run(() => WindowFocuser.FocusForSession(cwd, host, name, terminalHost));
            Log.Perf($"perf: row focus click total={sw.ElapsedMilliseconds}ms result={r}", sw.ElapsedMilliseconds, thresholdMs: 120);
            if (r is WindowFocuser.FocusResult.NotFound or WindowFocuser.FocusResult.FoundButFailed)
                System.Media.SystemSounds.Asterisk.Play();
        }
    }

    // ---- Show / corner anchoring ----

    public void ShowWidget()
    {
        // Force a clean visible state: undo any stray minimize, show if hidden, re-pin on-screen
        // (handles a monitor/resolution change that left it off-screen) and re-assert topmost+focus
        // (Topmost can silently drop after sleep/resume). Called on tray click and the "show" poke.
        if (WindowState != WindowState.Normal) WindowState = WindowState.Normal;
        if (!IsVisible) Show();
        Visibility = Visibility.Visible;
        ApplyAnchor();
        Topmost = false; Topmost = true;
        Activate();
        EnsureTopmost();   // WPF Topmost alone doesn't re-order from a background process — force it
    }

    /// <summary>Force the window into Windows' topmost Z-band via Win32, so it's really ABOVE
    /// everything (WPF's Topmost property alone leaves it behind when shown from the background at
    /// boot/resume). No focus stealing (SWP_NOACTIVATE), no move/resize. Called on every show and,
    /// while visible, on each poll so it can never silently sink behind other windows.</summary>
    public void EnsureTopmost()
    {
        try
        {
            var hwnd = new System.Windows.Interop.WindowInteropHelper(this).Handle;
            if (hwnd == IntPtr.Zero) return;
            SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        }
        catch { /* never let a Z-order tweak break the app */ }
    }

    /// <summary>Called from the tray menu's Position submenu.</summary>
    public void SetCorner(string corner)
    {
        _settings.Corner = corner;
        _settings.Save();
        ApplyLayout();
        ApplyAnchor();
    }

    /// <summary>Put the header bar on the side of the anchored corner: bottom corners
    /// keep the bar at the BOTTOM (rows grow upward above it); top corners at the top.</summary>
    private void ApplyLayout()
    {
        bool bottom = _settings.Corner.StartsWith("bottom", StringComparison.OrdinalIgnoreCase);
        var star = new GridLength(1, GridUnitType.Star);
        if (bottom)
        {
            // top→bottom: list (grows up) · usage · header bar pinned to the corner
            Row0.Height = star; Row1.Height = GridLength.Auto; Row2.Height = GridLength.Auto;
            Grid.SetRow(BodyArea, 0); Grid.SetRow(UsageArea, 1); Grid.SetRow(HeaderBar, 2);
            HeaderBar.CornerRadius = new CornerRadius(0, 0, 10, 10);
            UsageArea.BorderThickness = new Thickness(0, 1, 0, 1);
        }
        else
        {
            // top→bottom: header bar · list · usage at the bottom
            Row0.Height = GridLength.Auto; Row1.Height = star; Row2.Height = GridLength.Auto;
            Grid.SetRow(HeaderBar, 0); Grid.SetRow(BodyArea, 1); Grid.SetRow(UsageArea, 2);
            HeaderBar.CornerRadius = new CornerRadius(10, 10, 0, 0);
            UsageArea.BorderThickness = new Thickness(0, 1, 0, 0);
        }
        CollapseBtn.Content = CollapseGlyph();

        // Gear on the side AWAY from the screen edge: right-corner → gear far-left (menu
        // opens left), left-corner → gear on the right (menu opens right). Keeps the
        // settings menu off the app.
        bool right = _settings.Corner.Contains("right", StringComparison.OrdinalIgnoreCase);
        SettingsBtnLeft.Visibility = right ? Visibility.Visible : Visibility.Collapsed;
        SettingsBtnRight.Visibility = right ? Visibility.Collapsed : Visibility.Visible;
    }

    /// <summary>Pin the widget to its chosen corner of the primary work area.</summary>
    private void ApplyAnchor()
    {
        var wa = SystemParameters.WorkArea;
        double w = ActualWidth > 0 ? ActualWidth : Width;
        double h = ActualHeight > 0 ? ActualHeight : Height;
        bool right = _settings.Corner.EndsWith("right", StringComparison.OrdinalIgnoreCase);
        bool bottom = _settings.Corner.StartsWith("bottom", StringComparison.OrdinalIgnoreCase);
        Left = right ? wa.Right - w - EdgeMargin : wa.Left + EdgeMargin;
        Top = bottom ? wa.Bottom - h - EdgeMargin : wa.Top + EdgeMargin;
    }

    private void SnapToNearestCorner()
    {
        var wa = SystemParameters.WorkArea;
        double cx = Left + ActualWidth / 2, cy = Top + ActualHeight / 2;
        bool right = cx > (wa.Left + wa.Right) / 2;
        bool bottom = cy > (wa.Top + wa.Bottom) / 2;
        SetCorner((bottom ? "bottom" : "top") + "-" + (right ? "right" : "left"));
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void Set<T>(ref T field, T value, [CallerMemberName] string? n = null)
    {
        if (!Equals(field, value)) { field = value; PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n)); }
    }
}
