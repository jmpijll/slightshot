using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Windows;
using System.Windows.Threading;
using Slightshot.Core;
using Forms = System.Windows.Forms;

namespace Slightshot;

public partial class App : System.Windows.Application
{
    private Settings settings = new();
    private Forms.NotifyIcon? tray;
    private Icon? trayIcon;
    private HotKeyService? hotKeys;
    private OutputService? output;
    private SettingsWindow? preferences;
    private readonly List<OverlayWindow> overlays = [];
    private Mutex? instance;
    private bool ownsInstance;
    private bool capturing;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        if (e.Args.Length >= 1 && e.Args[0] == "--smoke-test")
        {
            try { SmokeTest.Run(e.Args.Length > 1 ? e.Args[1] : "artifacts"); Shutdown(0); }
            catch (Exception ex) { Console.Error.WriteLine(ex); Shutdown(1); }
            return;
        }
        instance = new Mutex(true, "Local\\Slightshot", out ownsInstance);
        if (!ownsInstance) { Shutdown(); return; }
        settings = Settings.Load();
        trayIcon = CreateTrayIcon();
        tray = new Forms.NotifyIcon { Icon = trayIcon, Text = "Slightshot", Visible = true };
        tray.DoubleClick += (_, _) => Dispatcher.InvokeAsync(BeginCapture);
        output = new OutputService(settings, (title, body) => tray.ShowBalloonTip(3000, title, body, Forms.ToolTipIcon.None));
        hotKeys = new HotKeyService(id => Dispatcher.InvokeAsync(() => { if (id == 1) BeginCapture(); else FullScreen(id == 2 ? CaptureAction.Save : CaptureAction.Copy); }));
        UpdateSettings();
    }

    private void UpdateSettings()
    {
        try { settings.Save(); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { Error($"Could not save settings.\n\n{ex.Message}"); }
        string[] failures = hotKeys!.Register(settings);
        var menu = new Forms.ContextMenuStrip();
        Add(menu, $"Capture Area    {settings.CaptureAreaHotKey}", BeginCapture);
        Add(menu, $"Capture Full Screen    {settings.SaveFullScreenHotKey}", () => FullScreen(CaptureAction.Save));
        Add(menu, $"Copy Full Screen    {settings.CopyFullScreenHotKey}", () => FullScreen(CaptureAction.Copy));
        menu.Items.Add(new Forms.ToolStripSeparator());
        Add(menu, "Open Screenshots Folder", () => { try { Directory.CreateDirectory(settings.SaveDirectory); Open(settings.SaveDirectory); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { Error(ex.Message); } });
        menu.Items.Add(new Forms.ToolStripSeparator());
        Add(menu, "Settings…", ShowSettings);
        menu.Items.Add(new Forms.ToolStripMenuItem("Check for Updates…") { Enabled = false });
        Add(menu, "About Slightshot", () => MessageBox.Show("Slightshot 0.1.0 for Windows\n\nA small screenshot tool with the same capture workflow as Slightshot on Mac.\n\ngithub.com/jmpijll/slightshot", "About Slightshot", MessageBoxButton.OK));
        menu.Items.Add(new Forms.ToolStripSeparator()); Add(menu, "Quit Slightshot", Shutdown);
        var old = tray!.ContextMenuStrip; tray.ContextMenuStrip = menu; old?.Dispose();
        if (failures.Length > 0) tray.ShowBalloonTip(6000, "Shortcut unavailable", $"Already in use or invalid: {string.Join(", ", failures)}. Capture from the tray or choose another shortcut in Settings.", Forms.ToolTipIcon.Warning);
    }

    private void Add(Forms.ContextMenuStrip menu, string label, Action action) => menu.Items.Add(label, null, (_, _) => Dispatcher.InvokeAsync(action));
    private void BeginCapture()
    {
        if (capturing || overlays.Count > 0) return;
        capturing = true;
        try
        {
            preferences?.Hide();
            var displays = ScreenCapture.CaptureAll(settings.CaptureCursor);
            var active = ScreenCapture.UnderPointer(displays);
            OverlayWindow? focus = null;
            foreach (var display in displays)
            {
                var window = new OverlayWindow(display, settings, display == active, TakeOver, Dismiss, (_, action, bitmap) => { Dismiss(); output!.Perform(action, bitmap); });
                overlays.Add(window); window.Show();
                if (display == active) focus = window;
            }
            if (focus != null)
            {
                var target = focus;
                Dispatcher.InvokeAsync(() => { if (overlays.Contains(target)) { target.Activate(); target.Focus(); } }, DispatcherPriority.Loaded);
            }
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException or ArgumentException or OutOfMemoryException) { Dismiss(); Error(ex.Message); }
        finally { capturing = false; }
    }
    private void TakeOver(OverlayWindow window)
    {
        foreach (var other in overlays.Where(other => other != window)) other.Relinquish();
        window.Activate(); window.Focus();
    }
    private void Dismiss()
    {
        foreach (var window in overlays) window.Close(); overlays.Clear();
        try { settings.Save(); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { Error(ex.Message); }
    }
    private void FullScreen(CaptureAction action)
    {
        if (capturing || overlays.Count > 0) return;
        capturing = true;
        try
        {
            var display = ScreenCapture.UnderPointer(ScreenCapture.CaptureAll(settings.CaptureCursor));
            var bitmap = AnnotationRenderer.Flatten(display, new RectD(0, 0, display.Width, display.Height), [], settings.NativeResolution);
            output!.Perform(action, bitmap);
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException or ArgumentException or OutOfMemoryException) { Error(ex.Message); }
        finally { capturing = false; }
    }
    private void ShowSettings()
    {
        if (overlays.Count > 0) Dismiss();
        if (preferences == null)
        {
            preferences = new SettingsWindow(settings);
            preferences.Closed += (_, _) => { preferences = null; UpdateSettings(); };
        }
        preferences.Show(); preferences.Activate();
    }
    internal static void Open(string path) => Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
    private static void Error(string text) => MessageBox.Show(text, "Slightshot", MessageBoxButton.OK, MessageBoxImage.Warning);
    private static Icon CreateTrayIcon()
    {
        using var bitmap = new Bitmap(32, 32); using var graphics = Graphics.FromImage(bitmap);
        graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        using var pen = new System.Drawing.Pen(System.Drawing.Color.FromArgb(235, 160, 160, 165), 3) { StartCap = System.Drawing.Drawing2D.LineCap.Round, EndCap = System.Drawing.Drawing2D.LineCap.Round };
        foreach (var p in new[] { new[] { 5, 12, 5, 5, 12, 5 }, new[] { 20, 5, 27, 5, 27, 12 }, new[] { 27, 20, 27, 27, 20, 27 }, new[] { 12, 27, 5, 27, 5, 20 } }) graphics.DrawLines(pen, [new(p[0], p[1]), new(p[2], p[3]), new(p[4], p[5])]);
        IntPtr handle = bitmap.GetHicon();
        try { using var icon = Icon.FromHandle(handle); return (Icon)icon.Clone(); }
        finally { NativeMethods.DestroyIcon(handle); }
    }
    protected override void OnExit(ExitEventArgs e)
    {
        hotKeys?.Dispose(); tray?.Dispose(); trayIcon?.Dispose();
        if (ownsInstance) instance?.ReleaseMutex(); instance?.Dispose(); base.OnExit(e);
    }
}
