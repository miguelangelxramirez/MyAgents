using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace MyAgents.Services;

/// <summary>
/// Self-installs (and can repair/uninstall) the hook scripts and registers them
/// with Claude Code (and Codex when enabled), across the native Windows home AND
/// every RUNNING WSL distro — the user never runs a script by hand. Idempotent,
/// backed up. Mirrors how claude-status-bar wires up its hooks on launch.
/// </summary>
public static class HookInstaller
{
    private const string Marker = "statusbar";
    private const string TitleEnv = "CLAUDE_CODE_DISABLE_TERMINAL_TITLE";

    public static void InstallInBackground(bool includeCodex)
        => Task.Run(() => Guard(() => InstallAll(includeCodex), "install"));

    public static void UninstallInBackground()
        => Task.Run(() => Guard(() => UninstallAll(), "uninstall"));

    public static void UninstallCodexInBackground()
        => Task.Run(() => Guard(() => ForEachTarget((settings, codex, dir, sep, node) =>
        { if (codex is not null) StripFile(codex, removeEnv: false); }), "uninstall-codex"));

    // ---- Codex MANAGED hooks (zero-friction: trusted by policy, no /hooks) ----
    // Written to /etc/codex/requirements.toml in each WSL distro via `wsl -u root`
    // (passwordless from Windows). Managed hooks bypass Codex's trust prompt.

    public static void InstallCodexManagedInBackground()
        => Task.Run(() => Guard(InstallCodexManaged, "codex-managed"));

    public static void UninstallCodexManagedInBackground()
        => Task.Run(() => Guard(UninstallCodexManaged, "codex-managed-uninstall"));

    // Managed hooks are honored only when BOTH the requirements.toml AND the hook
    // SCRIPTS live in a privileged (root-owned) location — not the user home (that
    // was why the first attempt was ignored). We put everything under /etc/codex.
    private const string ManagedDir = "/etc/codex/cchooks";

    private static void InstallCodexManaged()
    {
        foreach (var distro in ListRunningWslDistros())
            Guard(() =>
            {
                foreach (var f in new[] { "_common.js", "update.js", "lifecycle.js" })
                    WriteAsRoot(distro, $"{ManagedDir}/{f}", Script(f));
                // requirements.toml is SHARED with enterprise/MDM policy — write ONLY if it's
                // absent or already ours; NEVER clobber a real managed config (fall back to
                // process/transcript on such machines).
                WriteRequirementsIfOurs(distro, BuildCodexToml(ManagedDir));
                Log.Write($"codex-managed: wrote {ManagedDir} (+requirements.toml if safe) in {distro}");
            }, $"codex-managed:{distro}");
    }

    private static void UninstallCodexManaged()
    {
        foreach (var distro in ListRunningWslDistros())
            // Only remove it if it's OURS — never delete a user's real enterprise config.
            Guard(() => RunAsRoot(distro,
                "F=/etc/codex/requirements.toml; D=/etc/codex/cchooks; " +
                "if grep -q 'Managed by Claude Code App' \"$F\" 2>/dev/null; then rm -f \"$F\" \"$F.bak-ccapp\"; rm -rf \"$D\"; " +
                "elif [ -d \"$D\" ] && grep -q 'Claude Code App' \"$D/update.js\" 2>/dev/null; then rm -rf \"$D\"; fi"),
                $"codex-managed-uninstall:{distro}");
    }

    private static string BuildCodexToml(string dir)
    {
        var sb = new StringBuilder();
        sb.AppendLine("# Managed by Claude Code App - Codex session-status hooks (trusted by policy).");
        sb.AppendLine("[features]");
        sb.AppendLine("hooks = true");
        sb.AppendLine();
        sb.AppendLine("[hooks]");
        sb.AppendLine($"managed_dir = '{dir}'");
        sb.AppendLine();
        void Block(string evt, string script, string arg)
        {
            sb.AppendLine($"[[hooks.{evt}]]");
            sb.AppendLine($"[[hooks.{evt}.hooks]]");
            sb.AppendLine("type = \"command\"");
            sb.AppendLine($"command = 'node \"{dir}/{script}\" {arg} codex'");
            sb.AppendLine();
        }
        Block("SessionStart", "lifecycle.js", "start");
        Block("SessionEnd", "lifecycle.js", "end");
        Block("UserPromptSubmit", "update.js", "prompt");
        Block("PreToolUse", "update.js", "pre");
        Block("PostToolUse", "update.js", "post");
        Block("PermissionRequest", "update.js", "permreq");
        Block("Notification", "update.js", "notify");
        Block("Stop", "update.js", "stop");
        return sb.ToString();
    }

    /// <summary>Write requirements.toml as root ONLY if it's absent or already ours
    /// (carries our marker) — never overwrite a real enterprise/MDM managed config.</summary>
    private static void WriteRequirementsIfOurs(string distro, string content)
    {
        const string f = "/etc/codex/requirements.toml";
        // Both branches drain stdin so our piped content never breaks the pipe.
        var guard = $"F={f}; if [ -f \"$F\" ] && ! grep -q 'Managed by Claude Code App' \"$F\"; then cat >/dev/null; exit 9; fi; mkdir -p /etc/codex; cat > \"$F\"";
        var psi = WslRootPsi(distro, guard);
        psi.RedirectStandardInput = true;
        psi.StandardInputEncoding = new UTF8Encoding(false);
        using var p = Process.Start(psi);
        if (p is null) return;
        try { p.StandardInput.Write(content); p.StandardInput.Close(); } catch { }
        p.WaitForExit(8000);
        if (p.HasExited && p.ExitCode == 9)
            Log.Write($"codex-managed: {distro} has a FOREIGN requirements.toml — not touching it (fallback to process/transcript)");
    }

    /// <summary>Write <paramref name="content"/> to <paramref name="path"/> as root in WSL (passwordless), backing up once.</summary>
    private static void WriteAsRoot(string distro, string path, string content)
    {
        var psi = WslRootPsi(distro,
            $"mkdir -p \"$(dirname '{path}')\"; if [ -f '{path}' ] && [ ! -f '{path}.bak-ccapp' ]; then cp '{path}' '{path}.bak-ccapp'; fi; cat > '{path}.cctmp' && mv -f '{path}.cctmp' '{path}'");
        psi.RedirectStandardInput = true;
        psi.StandardInputEncoding = new UTF8Encoding(false);
        using var p = Process.Start(psi);
        if (p is null) return;
        p.StandardInput.Write(content);
        p.StandardInput.Close();
        p.WaitForExit(8000);
    }

    private static void RunAsRoot(string distro, string shCommand)
    {
        using var p = Process.Start(WslRootPsi(distro, shCommand));
        p?.WaitForExit(8000);
    }

    private static ProcessStartInfo WslRootPsi(string distro, string shCommand)
    {
        var psi = new ProcessStartInfo("wsl.exe")
        { RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
        foreach (var a in new[] { "-d", distro, "-u", "root", "--", "sh", "-c", shCommand }) psi.ArgumentList.Add(a);
        return psi;
    }

    private static void Guard(Action a, string what)
    { try { a(); } catch (Exception ex) { Log.Write($"{what}: {ex.Message}"); } }

    // ---- Install ----

    private static void InstallAll(bool includeCodex)
    {
        ForEachTarget((settingsPath, codexPath, sbDir, sep, node) =>
        {
            WriteScripts(sbDir);
            MergeHooks(settingsPath, node, sep, provider: null, setTitleEnv: true);
            MergeStatusLine(settingsPath, sbDir, node, sep);
            if (includeCodex && codexPath is not null && Directory.Exists(Path.GetDirectoryName(codexPath)!))
                MergeHooks(codexPath, node, sep, provider: "codex", setTitleEnv: false);
        });
    }

    private static void UninstallAll()
    {
        ForEachTarget((settingsPath, codexPath, sbDir, sep, node) =>
        {
            StripFile(settingsPath, removeEnv: true);
            if (codexPath is not null) StripFile(codexPath, removeEnv: false);
        });
    }

    /// <summary>
    /// Runs an action for the Windows home and each RUNNING WSL distro. The action
    /// gets: claude settings.json path, codex hooks.json path (null on Windows),
    /// the statusbar dir to write scripts to, the path separator the hook runtime
    /// uses, and the resolved `node` invocation token.
    /// </summary>
    private static void ForEachTarget(Action<string, string?, string, string, string> action)
    {
        // Native Windows
        Guard(() =>
        {
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            var sb = Path.Combine(home, ".claude", "statusbar");
            action(Path.Combine(home, ".claude", "settings.json"), null, sb, "\\", ResolveWindowsNode());
        }, "target:windows");

        // Running WSL distros only (never wake a stopped distro)
        foreach (var distro in ListRunningWslDistros())
            Guard(() =>
            {
                var wslHome = WslExec(distro, "printf %s \"$HOME\"");
                if (string.IsNullOrWhiteSpace(wslHome) || !wslHome.StartsWith('/')) return;
                var uncBase = $@"\\wsl.localhost\{distro}" + wslHome.Replace('/', '\\');
                var sbDir = wslHome + "/.claude/statusbar";
                var node = ResolveWslNode(distro);
                action(Path.Combine(uncBase, ".claude", "settings.json"),
                       Path.Combine(uncBase, ".codex", "hooks.json"),
                       Path.Combine(uncBase, ".claude", "statusbar"),  // UNC dir to WRITE scripts
                       "/", node);
            }, $"target:{distro}");
    }

    private static void WriteScripts(string sbDir)
    {
        Directory.CreateDirectory(Path.Combine(sbDir, "sessions.d"));
        foreach (var f in new[] { "_common.js", "update.js", "lifecycle.js", "statusline.js" })
        {
            var content = Script(f);
            if (string.IsNullOrEmpty(content)) continue;   // never blank out a live hook
            var dest = Path.Combine(sbDir, f);
            var tmp = dest + ".ccapp-tmp";
            try
            {
                // Write to a temp file, then atomically swap it in. A mid-write UNC/WSL hiccup
                // can then never leave a 0-byte hook (which would break EVERY Claude session,
                // since each hook requires _common.js). On failure the live file is untouched.
                File.WriteAllText(tmp, content);
                File.Move(tmp, dest, overwrite: true);
            }
            catch { try { if (File.Exists(tmp)) File.Delete(tmp); } catch { } }
        }
    }

    private static string Script(string name)
    {
        using var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("ccapp." + name)
                      ?? throw new InvalidOperationException("missing embedded " + name);
        using var r = new StreamReader(s);
        return r.ReadToEnd();
    }

    // ---- JSON merge / strip ----

    private static void MergeHooks(string path, string node, string sep, string? provider, bool setTitleEnv)
    {
        // sep is the runtime separator; the script dir as the hook runtime sees it.
        // For Windows that's the Windows statusbar dir; for WSL the /home/... path.
        // We reconstruct it from the settings path's directory for Windows, or it's
        // already passed via sep context — simpler: derive from provider-agnostic dir.
        var root = Load(path);
        Backup(path);

        if (setTitleEnv && root["env"] is JsonObject env0)
        {
            // We WANT Claude to title the tab (its task summary = a unique key we
            // match for precise focus). Remove any earlier disable flag we set.
            env0.Remove(TitleEnv);
            if (env0.Count == 0) root.Remove("env");
        }

        var hooks = root["hooks"] as JsonObject ?? new JsonObject();
        var scriptDir = ScriptDirFor(path, sep);
        string Cmd(string script, string evt)
            => $"{node} \"{scriptDir}{sep}{script}\" {evt}" + (provider is null ? "" : " " + provider);

        Add(hooks, "SessionStart", Cmd("lifecycle.js", "start"));
        Add(hooks, "SessionEnd", Cmd("lifecycle.js", "end"));
        Add(hooks, "UserPromptSubmit", Cmd("update.js", "prompt"));
        Add(hooks, "PreToolUse", Cmd("update.js", "pre"), "*");
        Add(hooks, "PostToolUse", Cmd("update.js", "post"), "*");
        Add(hooks, "PermissionRequest", Cmd("update.js", "permreq"), "*");
        Add(hooks, "Notification", Cmd("update.js", "notify"));
        Add(hooks, "Stop", Cmd("update.js", "stop"));
        root["hooks"] = hooks;

        Save(path, root);
    }

    /// <summary>
    /// Point Claude Code's single `statusLine` field at our wrapper, which captures the
    /// OFFICIAL rate_limits from stdin (no tokens, no endpoint). If the user already had a
    /// statusline we CHAIN it: save the original command to a sidecar so the wrapper runs it
    /// transparently and uninstall restores it. Never clobber a user's statusline silently.
    /// </summary>
    private static void MergeStatusLine(string path, string sbDir, string node, string sep)
    {
        var root = Load(path);
        Backup(path);
        var scriptDir = ScriptDirFor(path, sep);
        var ourCmd = $"{node} \"{scriptDir}{sep}statusline.js\"";
        var sidecar = Path.Combine(sbDir, "orig-statusline.txt");

        var existing = root["statusLine"] as JsonObject;
        var existingCmd = existing?["command"]?.GetValue<string>() ?? "";
        bool isOurs = existingCmd.Contains("statusline.js", StringComparison.OrdinalIgnoreCase);

        if (existing is not null && !isOurs && existingCmd.Length > 0)
        {
            // Preserve the user's command so the wrapper can run it and uninstall can restore it.
            try { File.WriteAllText(sidecar, existingCmd); } catch { }
            Log.Write($"statusline: chaining existing user statusline ({path})");
        }
        else if (existing is null)
        {
            // No prior statusline → drop any stale sidecar so we render our own line.
            try { if (File.Exists(sidecar)) File.Delete(sidecar); } catch { }
        }
        // (isOurs → re-install: keep any chained sidecar, just re-point the command.)

        // Mutate IN PLACE so we keep the user's other statusLine fields (padding, etc.) —
        // only the command swaps to our wrapper.
        var obj = existing ?? new JsonObject();
        obj["type"] = "command";
        obj["command"] = ourCmd;
        root["statusLine"] = obj;
        Save(path, root);
    }

    /// <summary>The statusbar dir as the hook runtime sees it (Windows path or /home path).</summary>
    private static string ScriptDirFor(string settingsOrHooksPath, string sep)
    {
        if (sep == "\\") // Windows: <home>\.claude\statusbar
        {
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            return Path.Combine(home, ".claude", "statusbar");
        }
        // WSL: derive /home/<user>/.claude/statusbar from the UNC path
        // \\wsl.localhost\<distro>\home\<user>\.claude\(settings.json|.codex\hooks.json)
        var p = settingsOrHooksPath.Replace('\\', '/');
        int idx = p.IndexOf("/home/", StringComparison.OrdinalIgnoreCase);
        if (idx < 0) idx = p.IndexOf("/root", StringComparison.OrdinalIgnoreCase);
        if (idx < 0) return "~/.claude/statusbar";
        var afterHost = p[idx..];                       // /home/<user>/.claude/...
        int claudeIdx = afterHost.IndexOf("/.c", StringComparison.OrdinalIgnoreCase);
        var homePart = claudeIdx > 0 ? afterHost[..claudeIdx] : afterHost;
        return homePart + "/.claude/statusbar";
    }

    private static void StripFile(string path, bool removeEnv)
    {
        if (!File.Exists(path)) return;
        var root = Load(path);
        string? sidecarToDelete = null;
        if (removeEnv && root["env"] is JsonObject env)
        {
            env.Remove(TitleEnv);
            if (env.Count == 0) root.Remove("env");
        }
        if (root["hooks"] is JsonObject hooks)
        {
            foreach (var evt in hooks.Select(kv => kv.Key).ToList())
            {
                var kept = new JsonArray();
                if (hooks[evt] is JsonArray arr)
                    foreach (var entry in arr)
                    {
                        var inner = entry?["hooks"] as JsonArray;
                        bool ours = inner is not null && inner.Any(h =>
                            (h?["command"]?.GetValue<string>() ?? "").Contains(Marker, StringComparison.OrdinalIgnoreCase));
                        if (!ours && entry is not null) kept.Add(entry.DeepClone());
                    }
                if (kept.Count == 0) hooks.Remove(evt); else hooks[evt] = kept;
            }
            if (hooks.Count == 0) root.Remove("hooks");
        }

        // statusLine: if it's ours, restore the user's chained original (sidecar) or remove ours.
        if ((root["statusLine"]?["command"]?.GetValue<string>() ?? "")
            .Contains("statusline.js", StringComparison.OrdinalIgnoreCase))
        {
            var sidecar = Path.Combine(Path.GetDirectoryName(path) ?? "", "statusbar", "orig-statusline.txt");
            string orig = "";
            try { if (File.Exists(sidecar)) orig = File.ReadAllText(sidecar).Trim(); } catch { }
            if (orig.Length > 0 && root["statusLine"] is JsonObject slObj)
                slObj["command"] = orig;          // restore the user's command, keep padding/etc.
            else
                root.Remove("statusLine");
            // Delete the sidecar ONLY after the restored settings.json is safely written
            // (below) — never before, or a crash mid-uninstall would lose the original.
            sidecarToDelete = sidecar;
        }

        Save(path, root);
        if (sidecarToDelete is not null)
            try { if (File.Exists(sidecarToDelete)) File.Delete(sidecarToDelete); } catch { }
    }

    private static void Add(JsonObject hooks, string evt, string command, string? matcher = null)
    {
        var kept = new JsonArray();
        if (hooks[evt] is JsonArray existing)
            foreach (var entry in existing)
            {
                var inner = entry?["hooks"] as JsonArray;
                bool ours = inner is not null && inner.Any(h =>
                    (h?["command"]?.GetValue<string>() ?? "").Contains(Marker, StringComparison.OrdinalIgnoreCase));
                if (!ours && entry is not null) kept.Add(entry.DeepClone());
            }
        var handler = new JsonObject { ["type"] = "command", ["command"] = command };
        var group = new JsonObject { ["hooks"] = new JsonArray { handler } };
        if (matcher is not null) group["matcher"] = matcher;
        kept.Add(group);
        hooks[evt] = kept;
    }

    private static JsonObject Load(string path)
    {
        try { if (File.Exists(path)) return JsonNode.Parse(File.ReadAllText(path))?.AsObject() ?? new JsonObject(); }
        catch (Exception ex) { Log.Write($"parse {path}: {ex.Message}"); }
        return new JsonObject();
    }

    private static void Backup(string path)
    { try { if (File.Exists(path) && !File.Exists(path + ".bak-ccapp")) File.Copy(path, path + ".bak-ccapp"); } catch { } }

    private static void Save(string path, JsonObject root)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }) + "\n");
    }

    // ---- node resolution + WSL helpers ----

    private static string ResolveWindowsNode()
    {
        try
        {
            var psi = new ProcessStartInfo("where.exe", "node")
            { RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true };
            using var p = Process.Start(psi);
            var o = p!.StandardOutput.ReadToEnd(); p.WaitForExit(3000);
            var line = o.Split('\n').Select(x => x.Trim()).FirstOrDefault(x => x.Length > 0);
            return string.IsNullOrEmpty(line) ? "node" : $"\"{line}\"";
        }
        catch { return "node"; }
    }

    private static string ResolveWslNode(string distro)
    {
        var path = WslExec(distro, "command -v node");
        return string.IsNullOrWhiteSpace(path) || !path.StartsWith('/') ? "node" : $"\"{path}\"";
    }

    private static string WslExec(string distro, string shCommand)
    {
        try
        {
            var psi = new ProcessStartInfo("wsl.exe")
            { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true, StandardOutputEncoding = Encoding.UTF8 };
            psi.ArgumentList.Add("-d"); psi.ArgumentList.Add(distro);
            psi.ArgumentList.Add("--"); psi.ArgumentList.Add("sh"); psi.ArgumentList.Add("-lc");
            psi.ArgumentList.Add(shCommand);
            using var p = Process.Start(psi);
            if (p is null) return "";
            var outp = p.StandardOutput.ReadToEnd().Trim().Replace("\r", "").Replace("\0", "");
            p.WaitForExit(5000);
            return outp.Split('\n').FirstOrDefault()?.Trim() ?? "";
        }
        catch { return ""; }
    }

    private static List<string> ListRunningWslDistros()
    {
        var list = new List<string>();
        try
        {
            var psi = new ProcessStartInfo("wsl.exe", "-l --running -q")
            { RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true, StandardOutputEncoding = Encoding.Unicode };
            using var p = Process.Start(psi);
            if (p is null) return list;
            var outp = p.StandardOutput.ReadToEnd(); p.WaitForExit(5000);
            foreach (var raw in outp.Split('\n'))
            {
                var name = raw.Replace("\r", "").Replace("\0", "").Trim();
                if (name.Length > 0) list.Add(name);
            }
        }
        catch { }
        return list;
    }
}
