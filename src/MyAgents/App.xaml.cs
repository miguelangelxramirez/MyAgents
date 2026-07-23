using System.IO;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Threading;
using MyAgents.Models;
using MyAgents.Services;
using MyAgents.Ui;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace MyAgents;

public partial class App : System.Windows.Application
{
    [DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr hIcon);

    private const int PollVisibleMs = 1000, PollHiddenMs = 2500;
    private const int RootsRefreshMs = 60000, UsageRefreshMs = 60000;

    private readonly AppSettings _settings = AppSettings.Load();
    private readonly SessionScanner _scanner = new();
    private readonly CodexScanner _codex = new();
    private readonly UsageService _usage = new();
    private readonly CodexUsageService _codexUsage = new();
    private readonly DispatcherTimer _poll = new();
    private readonly DispatcherTimer _usageTimer = new();

    private Forms.NotifyIcon _tray = null!;
    private Forms.ContextMenuStrip _menu = null!;
    private WidgetWindow _widget = null!;
    private bool _widgetClosed;   // set when the widget window is torn down → EnsureWidget() rebuilds it
    private string _iconState = "idle";
    private string _iconVisualKey = "";
    private int _iconPct = -1;                         // 5h usage % drawn on the tray icon (-1 = none)
    private IntPtr _iconHandle = IntPtr.Zero;
    private readonly Dictionary<string, string> _prevState = new(StringComparer.Ordinal);
    private (string cwd, string host, string name)? _lastPerm;   // session to focus from the toast
    private long _lastRootsRefreshMs;
    private long _lastProcMs;       // last scan ATTEMPT (throttle)
    private long _lastProcOkMs;     // last SUCCESSFUL scan (freshness for liveness)
    private const long LivenessFreshMs = 20_000;  // snapshot older than this → can't verify openness
    private const int StaleBridgeSeconds = 1800;  // when process scan is unavailable, only trust hook sessions written within 30 min — a stale pid from a pre-reboot file is NOT proof of life
    private readonly ProcessScanner _proc = new();
    private List<ProcessScanner.Proc>? _liveProcs;
    private List<SessionState> _lastSessions = new();
    private Mutex? _mutex;
    private bool _pollBusy;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // Launch stamp — FIRST thing, before the single-instance check, so EVERY start is recorded
        // (even an instance that immediately exits because another is already running). Lets us prove
        // from %APPDATA%\MyAgents\launch-log.txt whether Windows autostart actually fires at boot vs a
        // manual open — no guessing from a dateless perf log. Diagnostic; cheap; never fatal.
        try
        {
            var dir = System.IO.Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MyAgents");
            System.IO.Directory.CreateDirectory(dir);
            System.IO.File.AppendAllText(System.IO.Path.Combine(dir, "launch-log.txt"),
                $"{DateTime.Now:yyyy-MM-dd HH:mm:ss}  launch  pid={Environment.ProcessId}  exe={Environment.ProcessPath}\n");
        }
        catch { }

        // ROOT robustness: an unhandled exception must NEVER close the app. If it did, the tray
        // icon vanishes and the app is hard to relaunch. Swallow UI-thread exceptions (keep the
        // tray alive) and log the rest — a monitor tool staying up matters more than any one error.
        DispatcherUnhandledException += (_, ex) =>
        {
            try { Log.Write("unhandled(ui): " + ex.Exception); } catch { }
            ex.Handled = true;   // keep running
        };
        AppDomain.CurrentDomain.UnhandledException += (_, ex) =>
        { try { Log.Write("unhandled(domain): " + ex.ExceptionObject); } catch { } };
        System.Threading.Tasks.TaskScheduler.UnobservedTaskException += (_, ex) =>
        { try { Log.Write("unhandled(task): " + ex.Exception); } catch { } ex.SetObserved(); };

        _mutex = new Mutex(true, "MyAgents.SingleInstance", out bool created);
        const string showEventName = "MyAgents.ShowWidget";
        if (!created)
        {
            // Already running. Instead of silently dying, POKE the live instance to show its
            // widget and come to the front — so re-launching the exe (or a shortcut/pin) is a
            // reliable way to open it without hunting for the tray icon in the overflow.
            try { EventWaitHandle.OpenExisting(showEventName).Set(); } catch { }
            Shutdown();
            return;
        }
        // Primary instance: listen for "show" pokes from later launches.
        var showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, showEventName);
        new Thread(() =>
        {
            while (true)
            {
                try { showEvent.WaitOne(); } catch { break; }
                try { Dispatcher.Invoke(() => { SetWidgetVisible(true); try { _widget.Activate(); } catch { } }); } catch { }
            }
        })
        { IsBackground = true }.Start();

        CreateWidget();   // build the widget + wire its events (also rebuilt on demand if ever torn down)

        // The app wires up its own Claude hooks (Windows + every WSL distro) — the
        // user never runs an install script. Codex is read straight from its rollout
        // transcripts (no hooks, no trust step), so remove any legacy Codex hooks.
        // Claude hooks (user settings). Codex = MANAGED hooks under /etc/codex
        // (root-owned → trusted by policy, zero /hooks, survives auto-updates).
        HookInstaller.InstallInBackground(includeCodex: false);
        if (_settings.CodexEnabled)
        {
            HookInstaller.InstallCodexManagedInBackground();
            HookInstaller.UninstallCodexInBackground();   // drop any old user-level Codex hooks
        }
        else HookInstaller.UninstallCodexManagedInBackground();

        StartupManager.MigrateLegacyName();   // clean up any pre-rename "ClaudeCodeApp" autostart entry
        ShortcutManager.EnsureStartMenuShortcut();   // so the user can reopen it from the Start menu after closing
        BuildTray();

        _lastRootsRefreshMs = Environment.TickCount64;
        _poll.Interval = TimeSpan.FromMilliseconds(PollVisibleMs);
        _poll.Tick += async (_, _) => await PollAsync();
        _poll.Start();

        _usageTimer.Interval = TimeSpan.FromMilliseconds(UsageRefreshMs);
        _usageTimer.Tick += async (_, _) => await RefreshUsageAsync();
        _usageTimer.Start();

        _ = PollAsync();
        _ = RefreshUsageAsync();

        if (_settings.WidgetVisible)
        {
            _widget.ShowWidget();
            // At boot the widget can end up BEHIND the other startup apps' windows. Bring it back to
            // the front once, a few seconds later, when the logon window-storm has settled — so the
            // user sees it on its own without hunting the tray-overflow icon.
            var settle = new DispatcherTimer { Interval = TimeSpan.FromSeconds(6) };
            settle.Tick += (_, _) => { settle.Stop(); try { if (_settings.WidgetVisible && !_widgetClosed) _widget.ShowWidget(); } catch { } };
            settle.Start();
        }

        // First launch: turn ON "Start with Windows" by default so it's always there on every boot
        // (a monitor you have to re-launch by hand isn't a monitor). Transparent + reversible: we tell
        // the user and they can switch it off in the ⚙ menu. Done ONCE — if they later disable it, we
        // never silently re-enable.
        if (!_settings.FirstRunDone)
        {
            _settings.FirstRunDone = true;
            _settings.Save();
            try
            {
                StartupManager.SetEnabled(true);
                _tray.ShowBalloonTip(6000, "MyAgents",
                    "Set to start with Windows (turn off in the ⚙ menu). Find it anytime: press ⊞ Win and type \"MyAgents\".",
                    Forms.ToolTipIcon.Info);
            }
            catch { }
        }

        _ = CheckForUpdatesAsync();   // passive, opt-out, once/day — shows a small notice if a newer release exists
    }

    /// <summary>Best-effort background update check. Never throws, never blocks the UI; on a newer
    /// release it shows a small "update available" link in the widget header (the app never
    /// self-updates — clicking opens the Releases page).</summary>
    private async Task CheckForUpdatesAsync()
    {
        try
        {
            var r = await UpdateCheckService.CheckAsync(_settings);
            if (r is { } res)
                Dispatcher.Invoke(() => _widget.SetUpdateAvailable(res.Version, res.Url));
        }
        catch { /* non-fatal */ }
    }

    private void BuildTray()
    {
        var menu = new Forms.ContextMenuStrip();
        _menu = menu;
        menu.Items.Add("Show / hide widget", null, (_, _) => ToggleWidget());
        menu.Items.Add("Refresh", null, (_, _) => { _lastRootsRefreshMs = 0; _ = PollAsync(); _ = RefreshUsageAsync(); });
        menu.Items.Add("Export diagnostics", null, async (_, _) => await ExportDiagnosticsAsync());
        menu.Items.Add("Restart WSL (fix stuck sessions)", null, (_, _) => RestartWsl());
        menu.Items.Add(new Forms.ToolStripSeparator());

        var usage = new Forms.ToolStripMenuItem("Show usage (5h / 7d — official, no token)") { Checked = _settings.UsageEnabled };
        usage.Click += (_, _) =>
        {
            _settings.UsageEnabled = !_settings.UsageEnabled;
            _settings.Save();
            usage.Checked = _settings.UsageEnabled;
            _ = RefreshUsageAsync();
        };
        menu.Items.Add(usage);

        var notif = new Forms.ToolStripMenuItem("Notify when a session needs me") { Checked = _settings.NotificationsEnabled };
        notif.Click += (_, _) => { _settings.NotificationsEnabled = !_settings.NotificationsEnabled; _settings.Save(); notif.Checked = _settings.NotificationsEnabled; };
        menu.Items.Add(notif);

        var codex = new Forms.ToolStripMenuItem("Show Codex sessions") { Checked = _settings.CodexEnabled };
        codex.Click += (_, _) =>
        {
            _settings.CodexEnabled = !_settings.CodexEnabled;
            _settings.Save();
            codex.Checked = _settings.CodexEnabled;
            if (_settings.CodexEnabled)
            {
                HookInstaller.InstallCodexManagedInBackground();
                HookInstaller.UninstallCodexInBackground();   // drop any old user-level Codex hooks
                _codex.RefreshRoots();
                _ = PollAsync();
                _tray.ShowBalloonTip(7000, "Codex enabled",
                    "Zero setup — no /hooks needed. Restart your Codex sessions to pick it up.", Forms.ToolTipIcon.Info);
            }
            else HookInstaller.UninstallCodexManagedInBackground();
        };
        menu.Items.Add(codex);

        var pos = new Forms.ToolStripMenuItem("Position");
        foreach (var (label, corner) in new[] { ("Bottom-right", "bottom-right"), ("Bottom-left", "bottom-left"), ("Top-right", "top-right"), ("Top-left", "top-left") })
            pos.DropDownItems.Add(label, null, (_, _) => _widget.SetCorner(corner));
        menu.Items.Add(pos);

        var startup = new Forms.ToolStripMenuItem("Start with Windows") { Checked = StartupManager.IsEnabled() };
        startup.Click += (_, _) => { StartupManager.SetEnabled(!StartupManager.IsEnabled()); startup.Checked = StartupManager.IsEnabled(); };
        menu.Items.Add(startup);

        var updates = new Forms.ToolStripMenuItem("Check for updates (once a day)") { Checked = _settings.UpdateCheckEnabled };
        updates.Click += (_, _) =>
        {
            _settings.UpdateCheckEnabled = !_settings.UpdateCheckEnabled;
            _settings.Save();
            updates.Checked = _settings.UpdateCheckEnabled;
            if (_settings.UpdateCheckEnabled) { _settings.LastUpdateCheckUnix = 0; _ = CheckForUpdatesAsync(); }
        };
        menu.Items.Add(updates);

        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Repair hooks", null, (_, _) =>
        {
            HookInstaller.InstallInBackground(includeCodex: false);
            if (_settings.CodexEnabled)
            {
                HookInstaller.InstallCodexManagedInBackground();
                HookInstaller.UninstallCodexInBackground();
            }
            _tray.ShowBalloonTip(4000, "MyAgents", "Reinstalling hooks… restart your sessions after this.", Forms.ToolTipIcon.Info);
        });
        menu.Items.Add("Uninstall hooks", null, (_, _) =>
        {
            HookInstaller.UninstallInBackground();
            HookInstaller.UninstallCodexManagedInBackground();
            ShortcutManager.RemoveStartMenuShortcut();
            _tray.ShowBalloonTip(4000, "MyAgents", "Hooks removed. Restart your sessions to clear them.", Forms.ToolTipIcon.Info);
        });
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Exit", null, (_, _) => Quit());

        _tray = new Forms.NotifyIcon { Visible = true, Text = "MyAgents", ContextMenuStrip = menu };
        _tray.MouseClick += (_, ev) => { if (ev.Button == Forms.MouseButtons.Left) ToggleWidget(); };
        _tray.BalloonTipClicked += async (_, _) =>
        {
            SetWidgetVisible(true);
            if (_lastPerm is { } p) await Task.Run(() => WindowFocuser.FocusForSession(p.cwd, p.host, p.name));
        };
        UpdateIcon("idle");
    }

    private async Task PollAsync()
    {
        if (_pollBusy) return;
        _pollBusy = true;
        var total = Stopwatch.StartNew();
        List<SessionState> sessions;
        long bgMs = 0;
        try
        {
            var bg = Stopwatch.StartNew();
            sessions = await Task.Run(BuildSessionSnapshot);
            bgMs = bg.ElapsedMilliseconds;
        }
        catch (Exception ex)
        {
            Log.Write("perf: poll background failed: " + ex.Message);
            sessions = new();
        }

        try
        {
            NotifyPermissions(sessions);
            _lastSessions = sessions;

            if (_widget.IsVisible) { _widget.UpdateSessions(sessions); _widget.EnsureTopmost(); }

            string agg = sessions.Any(s => s.NeedsAttention) ? "permission"
                       : sessions.Any(s => s.IsBusy) ? "busy" : "idle";
            UpdateIcon(agg);

            int busy = sessions.Count(s => s.IsBusy), perm = sessions.Count(s => s.NeedsAttention);
            var text = $"MyAgents — {sessions.Count} session(s), {busy} working" + (perm > 0 ? $", {perm} awaiting you" : "");
            _tray.Text = text.Length <= 63 ? text : text[..63];

            var want = TimeSpan.FromMilliseconds(_widget.IsVisible ? PollVisibleMs : PollHiddenMs);
            if (_poll.Interval != want) _poll.Interval = want;
        }
        finally
        {
            Log.Perf($"perf: poll total={total.ElapsedMilliseconds}ms background={bgMs}ms sessions={sessions.Count}", total.ElapsedMilliseconds);
            _pollBusy = false;
        }
    }

    private List<SessionState> BuildSessionSnapshot()
    {
        var sw = Stopwatch.StartNew();
        if (Environment.TickCount64 - _lastRootsRefreshMs >= RootsRefreshMs)
        {
            _scanner.RefreshRoots();
            _codex.RefreshRoots();
            _proc.RefreshRoots();
            _lastRootsRefreshMs = Environment.TickCount64;
        }

        List<SessionState> sessions;
        long scanMs;
        var scan = Stopwatch.StartNew();
        try { sessions = _scanner.Scan(); }
        catch { sessions = new(); }
        scanMs = scan.ElapsedMilliseconds;

        if (_settings.CodexEnabled)
            try
            {
                // Prefer precise hook data (already in sessions via sessions.d); fill any
                // gaps from rollout transcripts, skipping sessions the hooks already cover
                // by id OR by provider+cwd. The latter prevents a hook row and a rollout
                // row for the same Codex terminal showing as duplicates.
                AddCodexFallbacks(sessions, _codex.Scan());
            }
            catch { }

        sessions = ApplyLiveness(sessions);
        Log.Perf($"perf: snapshot total={sw.ElapsedMilliseconds}ms claudeScan={scanMs}ms sessions={sessions.Count}", sw.ElapsedMilliseconds);
        return sessions;
    }

    private static void AddCodexFallbacks(List<SessionState> sessions, IEnumerable<SessionState> codex)
    {
        var ids = sessions.Select(s => s.SessionId).ToHashSet(StringComparer.Ordinal);
        var preciseKeys = sessions
            .Where(s => !s.SessionId.StartsWith("proc:", StringComparison.Ordinal))
            .Select(s => ProcessScanner.Key(s.Provider, s.Cwd))
            .ToHashSet(StringComparer.Ordinal);

        foreach (var c in codex)
        {
            if (ids.Contains(c.SessionId)) continue;
            var key = ProcessScanner.Key(c.Provider, c.Cwd);
            if (preciseKeys.Contains(key)) continue;
            sessions.Add(c);
            ids.Add(c.SessionId);
        }
    }

    /// <summary>
    /// Robust openness via live processes: a session is OPEN iff a claude/codex
    /// process exists for it (by pid, or by provider+cwd — survives reboots and a
    /// changed pid). Also DISCOVERS reopened/idle sessions that have a live process
    /// but no hook file yet. Replaces the fragile pid-reaper + transcript timing.
    /// </summary>
    private List<SessionState> ApplyLiveness(List<SessionState> sessions)
    {
        // Refresh the live-process snapshot every ~3 s; only replace it on a
        // non-empty result so a transient wsl hiccup doesn't wipe everything.
        if (_liveProcs is null || Environment.TickCount64 - _lastProcMs >= 4000)
        {
            try { var scan = _proc.Scan(); if (scan.Count > 0) { _liveProcs = scan; _lastProcOkMs = Environment.TickCount64; } }
            catch { }
            _lastProcMs = Environment.TickCount64;
        }

        // Liveness is only trustworthy when the last SUCCESSFUL process scan is recent.
        // If WSL is unavailable (this machine's wsl.exe is intermittently flaky) the snapshot
        // goes stale; trusting it then resurrects closed sessions — the "stuck siia-gen" phantom,
        // where a Codex transcript-fallback row (no pid) is shown because we can't confirm it died.
        // Degrade honestly: keep real pid-bearing sessions, but DROP speculative pid-less rows
        // (transcript/synthetic) and skip discovery until a fresh scan returns.
        bool fresh = _liveProcs is { Count: > 0 } && Environment.TickCount64 - _lastProcOkMs < LivenessFreshMs;
        if (!fresh)
        {
            // Process scan unavailable (right after boot before WSL is ready, or a WSL exec blip). We
            // can't verify openness, so bridge with hook sessions — but ONLY recently-written ones.
            // A stored pid is NOT proof of life across a reboot: stale hook files keep their last pid
            // AND their last state (some "thinking"/"tool"), so trusting every pid>0 resurrects dead
            // sessions as phantoms ("9 open · 2 working" on a fresh boot). Requiring a recent hook
            // write drops day-old ghosts while preserving a genuinely active session during a brief
            // blip (it reappears via liveness the moment a scan succeeds anyway).
            var survivors = sessions.Where(s => s.Pid > 0 && !s.IsStale(StaleBridgeSeconds)).ToList();
            Log.Write($"liveness: STALE (proc scan unavailable, {(Environment.TickCount64 - _lastProcOkMs) / 1000}s old) " +
                      $"in={sessions.Count} kept={survivors.Count} — kept only recent pid rows, dropped ghosts + pid-less, skipped discovery");
            return survivors;
        }

        var live = _liveProcs!;
        var livePids = live.Select(p => p.Pid).ToHashSet();
        var liveKeys = live.Select(p => ProcessScanner.Key(p.Provider, p.Cwd)).ToHashSet(StringComparer.Ordinal);

        // Per-session pid when we have it (precise — closing one of several sessions
        // in the same folder removes only it); cwd-key only for pid-less rows
        // (transcript/synthetic). Stale hook files after a reboot (dead pid) get
        // dropped and the reopened session reappears via discovery below.
        var kept = sessions.Where(s =>
            s.Pid > 0 ? livePids.Contains(s.Pid)
                      : liveKeys.Contains(ProcessScanner.Key(s.Provider, s.Cwd))).ToList();

        // Discover live processes with no session entry yet (e.g. reopened after a reboot, still idle).
        var keptKeys = kept.Select(s => ProcessScanner.Key(s.Provider, s.Cwd)).ToHashSet(StringComparer.Ordinal);
        // Dedup by PID too: a hook session's recorded cwd can differ from its live
        // process's /proc/<pid>/cwd (the CLI was launched from a parent dir), so the
        // SAME process must not appear both as its hook row and as a synthetic row.
        var keptPids = kept.Where(s => s.Pid > 0).Select(s => s.Pid).ToHashSet();
        long now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        foreach (var pr in live)
        {
            if (pr.Origin == "Windows" || pr.Cwd.Length == 0) continue;
            if (keptPids.Contains(pr.Pid)) continue;
            var key = ProcessScanner.Key(pr.Provider, pr.Cwd);
            if (!keptKeys.Add(key)) continue;
            string? nm = string.Equals(pr.Provider, "codex", StringComparison.OrdinalIgnoreCase) ? _codex.NameForCwd(pr.Cwd) : null;
            kept.Add(Synthetic(pr, now, nm));
            keptPids.Add(pr.Pid);
        }
        Log.Write($"liveness: fresh procs={live.Count} in={sessions.Count} kept={kept.Count} " +
                  $"[{string.Join(", ", live.Select(p => p.Provider + ":" + Path.GetFileName(p.Cwd.TrimEnd('/'))))}]");
        return kept;
    }

    private static SessionState Synthetic(ProcessScanner.Proc pr, long now, string? name = null)
    {
        var cwd = pr.Cwd.Replace('\\', '/').TrimEnd('/');
        return new SessionState
        {
            Provider = pr.Provider,
            Name = name ?? "",
            SessionId = "proc:" + pr.Provider + ":" + cwd,
            Cwd = pr.Cwd,
            Project = cwd.Length > 0 ? Path.GetFileName(cwd) : "",
            State = "idle",
            Host = "wsl:" + pr.Origin,
            TerminalHost = "",
            Origin = pr.Origin,
            Pid = pr.Pid,
            NowUnix = now,
            Ts = now,
        };
    }

    /// <summary>Toast + sound the moment a session starts awaiting your permission.</summary>
    private void NotifyPermissions(List<SessionState> sessions)
    {
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var s in sessions)
        {
            ids.Add(s.SessionId);
            var prev = _prevState.GetValueOrDefault(s.SessionId, "");
            if (s.NeedsAttention && prev != "permission" && _settings.NotificationsEnabled)
            {
                var label = !string.IsNullOrWhiteSpace(s.Name) ? s.Name : string.IsNullOrEmpty(s.Project) ? "session" : s.Project;
                var prov = string.Equals(s.Provider, "codex", StringComparison.OrdinalIgnoreCase) ? "Codex" : "Claude";
                _lastPerm = (s.Cwd, s.Host, s.Name);
                try { _tray.ShowBalloonTip(6000, "Needs your permission", $"{prov} · {label}", Forms.ToolTipIcon.Warning); } catch { }
                try { System.Media.SystemSounds.Exclamation.Play(); } catch { }
            }
            _prevState[s.SessionId] = s.State;
        }
        foreach (var k in _prevState.Keys.Where(k => !ids.Contains(k)).ToList()) _prevState.Remove(k);
    }

    private async Task RefreshUsageAsync()
    {
        if (!_settings.UsageEnabled)
        {
            _widget.SetUsage(new UsageInfo { Status = UsageStatus.Disabled });
            _widget.SetCodexUsage(new UsageInfo { Status = UsageStatus.Disabled });
            _iconPct = -1; UpdateIcon(_iconState);
            return;
        }

        UsageInfo info;
        try { info = await Task.Run(_usage.FetchAsync); }
        catch { info = new UsageInfo { Status = UsageStatus.Error }; }
        _widget.SetUsage(info);
        _iconPct = info.HasData ? (int)Math.Round(info.SessionPercent) : -1;
        UpdateIcon(_iconState);

        if (_settings.CodexEnabled)
        {
            UsageInfo cx;
            try { cx = await Task.Run(_codexUsage.FetchAsync); }
            catch { cx = new UsageInfo { Status = UsageStatus.Error }; }
            _widget.SetCodexUsage(cx);
        }
        else _widget.SetCodexUsage(new UsageInfo { Status = UsageStatus.Disabled });
    }

    private async Task ExportDiagnosticsAsync()
    {
        try
        {
            var sessions = _lastSessions.ToList();
            var path = await Task.Run(() => DiagnosticsService.Export(_settings, sessions));
            _tray.ShowBalloonTip(6000, "MyAgents diagnostics", path, Forms.ToolTipIcon.Info);
            try { Process.Start(new ProcessStartInfo("notepad.exe", $"\"{path}\"") { UseShellExecute = false }); } catch { }
        }
        catch (Exception ex)
        {
            Log.Write("diagnostics: " + ex.Message);
            try { _tray.ShowBalloonTip(4000, "Diagnostics failed", ex.Message, Forms.ToolTipIcon.Error); } catch { }
        }
    }

    /// <summary>(Re)create the widget window and wire its events. Called at startup and again by
    /// EnsureWidget() if the window is ever torn down, so the tray click / "show" poke can ALWAYS
    /// bring it back — a monitor tool must never end up with no window and no way to reopen it.</summary>
    private void CreateWidget()
    {
        _widget = new WidgetWindow(_settings);
        _widgetClosed = false;
        _widget.Closed += (_, _) => _widgetClosed = true;
        _widget.CloseRequested += () => SetWidgetVisible(false);
        _widget.SettingsRequested += () =>
        {
            // Open the menu into the empty quadrant (away from the corner the widget sits in) so it
            // never overlaps the app — e.g. bottom-right widget → menu grows up-left.
            var c = _settings.Corner ?? "bottom-right";
            var dir = (c.Contains("bottom"), c.Contains("right")) switch
            {
                (true, true) => Forms.ToolStripDropDownDirection.AboveLeft,
                (true, false) => Forms.ToolStripDropDownDirection.AboveRight,
                (false, true) => Forms.ToolStripDropDownDirection.BelowLeft,
                _ => Forms.ToolStripDropDownDirection.BelowRight,
            };
            if (_menu?.Visible == true) { _menu.Close(); return; }   // 2nd click on the gear closes it
            _menu?.Show(Forms.Cursor.Position, dir);
        };
    }

    private void EnsureWidget()
    {
        if (_widget is null || _widgetClosed) CreateWidget();
    }

    private void ToggleWidget()
    {
        // Hide only when the widget is genuinely up on screen; in EVERY other state (hidden, stuck
        // after resume, off-screen, or torn down) rebuild if needed and force it back to the front.
        bool up;
        try { up = !_widgetClosed && _widget is { IsVisible: true }; }
        catch { up = false; }
        SetWidgetVisible(!up);
    }

    private void SetWidgetVisible(bool visible)
    {
        if (visible)
        {
            EnsureWidget();
            try { _widget.ShowWidget(); }
            catch (Exception ex)
            {
                // The window was torn down (closed/disposed after resume, DPI change, etc.) —
                // rebuild a fresh one and show that. The click NEVER silently does nothing.
                Log.Write("show: rebuilding widget after " + ex.Message);
                CreateWidget();
                try { _widget.ShowWidget(); } catch (Exception ex2) { Log.Write("show failed: " + ex2.Message); }
            }
            _ = PollAsync();
        }
        else { try { _widget.Hide(); } catch { } }

        _settings.WidgetVisible = visible;
        _settings.Save();
    }

    /// <summary>Tray icon: a coloured dot, or the 5h usage % when usage is on.
    /// Recreated only when the state or the % changes.</summary>
    private void UpdateIcon(string state)
    {
        _iconState = state;
        string key = state + "|" + _iconPct;
        if (key == _iconVisualKey) return;
        _iconVisualKey = key;

        var stateOnly = state;
        var c = stateOnly switch
        {
            "permission" => Drawing.Color.FromArgb(235, 190, 70),
            "busy" => Drawing.Color.FromArgb(217, 119, 87),
            _ => Drawing.Color.FromArgb(120, 120, 128),
        };

        using var bmp = new Drawing.Bitmap(32, 32);
        using (var g = Drawing.Graphics.FromImage(bmp))
        {
            g.SmoothingMode = Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.TextRenderingHint = Drawing.Text.TextRenderingHint.AntiAliasGridFit;
            g.Clear(Drawing.Color.Transparent);
            if (_iconPct >= 0)
            {
                // Usage % badge: rounded chip + the number, tinted by how full it is.
                var fill = _iconPct >= 90 ? Drawing.Color.FromArgb(226, 108, 108)
                         : _iconPct >= 70 ? Drawing.Color.FromArgb(232, 170, 80)
                         : Drawing.Color.FromArgb(217, 119, 87);
                using var b = new Drawing.SolidBrush(fill);
                g.FillEllipse(b, 1, 1, 30, 30);
                var txt = _iconPct >= 100 ? "99" : _iconPct.ToString();
                using var f = new Drawing.Font("Segoe UI", txt.Length >= 2 ? 13f : 15f, Drawing.FontStyle.Bold, Drawing.GraphicsUnit.Pixel);
                using var tb = new Drawing.SolidBrush(Drawing.Color.White);
                var sz = g.MeasureString(txt, f);
                g.DrawString(txt, f, tb, (32 - sz.Width) / 2f, (32 - sz.Height) / 2f);
            }
            else
            {
                // A little robot (matches the widget's busy glyph), tinted by state.
                using var brush = new Drawing.SolidBrush(c);
                g.FillRectangle(brush, 15, 3, 2, 5);            // antenna stalk
                g.FillEllipse(brush, 12, 0, 8, 8);             // antenna bulb
                using (var head = RoundedRect(5, 9, 22, 20, 6))
                    g.FillPath(brush, head);                   // head
                using var eye = new Drawing.SolidBrush(Drawing.Color.FromArgb(248, 248, 252));
                g.FillEllipse(eye, 10, 15, 5, 5);              // eyes
                g.FillEllipse(eye, 17, 15, 5, 5);
            }
        }
        IntPtr newHandle = bmp.GetHicon();
        var oldIcon = _tray.Icon;
        IntPtr oldHandle = _iconHandle;

        _tray.Icon = Drawing.Icon.FromHandle(newHandle);
        _iconHandle = newHandle;

        oldIcon?.Dispose();
        if (oldHandle != IntPtr.Zero) DestroyIcon(oldHandle);
    }

    private static Drawing.Drawing2D.GraphicsPath RoundedRect(int x, int y, int w, int h, int r)
    {
        var p = new Drawing.Drawing2D.GraphicsPath();
        int d = r * 2;
        p.AddArc(x, y, d, d, 180, 90);
        p.AddArc(x + w - d, y, d, d, 270, 90);
        p.AddArc(x + w - d, y + h - d, d, d, 0, 90);
        p.AddArc(x, y + h - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    /// <summary>Run `wsl --shutdown` to recover a crashed WSL service (E_UNEXPECTED). This CLOSES
    /// all WSL terminals, so warn first; the user reopens them and the app picks them back up.</summary>
    private void RestartWsl()
    {
        try
        {
            Process.Start(new ProcessStartInfo("wsl.exe", "--shutdown") { UseShellExecute = false, CreateNoWindow = true });
            Wsl.ExecBroken = false;
            _tray.ShowBalloonTip(7000, "WSL restarting",
                "Your WSL terminals will close. Reopen them (and your Claude/Codex sessions) — MyAgents will pick them back up.",
                Forms.ToolTipIcon.Info);
        }
        catch (Exception ex) { Log.Write("wsl-shutdown: " + ex.Message); }
    }

    private void Quit()
    {
        _poll.Stop();
        _usageTimer.Stop();
        _tray.Visible = false;
        _tray.Dispose();
        if (_iconHandle != IntPtr.Zero) DestroyIcon(_iconHandle);
        _widget.Close();
        _mutex?.ReleaseMutex();
        Shutdown();
    }
}
