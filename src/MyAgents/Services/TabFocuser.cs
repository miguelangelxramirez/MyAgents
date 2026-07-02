using System.Windows.Automation;

namespace MyAgents.Services;

/// <summary>
/// Selects the exact Windows Terminal TAB for a session via UI Automation
/// (WT exposes each tab as a TabItem whose Name is the tab title). This is what
/// makes click-to-focus land on the right tab, not just the right window.
/// </summary>
public static class TabFocuser
{
    /// <summary>
    /// Find a WT tab whose title contains one of the candidates, select it, and
    /// return its window handle (so the caller can bring the window forward).
    /// </summary>
    public static bool TrySelectTab(IReadOnlyList<string> candidates, out IntPtr windowHandle)
    {
        windowHandle = IntPtr.Zero;
        try
        {
            var root = AutomationElement.RootElement;
            var wtCond = new PropertyCondition(AutomationElement.ClassNameProperty, "CASCADIA_HOSTING_WINDOW_CLASS");
            var windows = root.FindAll(TreeScope.Children, wtCond);

            foreach (AutomationElement win in windows)
            {
                var tabs = win.FindAll(TreeScope.Descendants,
                    new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.TabItem));

                foreach (AutomationElement tab in tabs)
                {
                    string name;
                    try { name = tab.Current.Name ?? ""; } catch { continue; }
                    if (name.Length == 0) continue;

                    if (candidates.Any(c => c.Length >= 3 && name.Contains(c, StringComparison.OrdinalIgnoreCase)))
                    {
                        try
                        {
                            if (tab.TryGetCurrentPattern(SelectionItemPattern.Pattern, out var p))
                                ((SelectionItemPattern)p).Select();
                        }
                        catch { /* selection may still have worked; fall through */ }

                        try { windowHandle = new IntPtr(win.Current.NativeWindowHandle); } catch { }
                        Log.Write($"uia: selected tab \"{name}\" (hwnd={windowHandle:X})");
                        return true;
                    }
                }
            }
            Log.Write("uia: no WT tab matched");
        }
        catch (Exception ex) { Log.Write("uia: error " + ex.Message); }
        return false;
    }
}
