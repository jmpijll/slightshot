using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Windows;
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
    private RecordingCoordinator? recording;
    private SettingsWindow? preferences;
    private OverlayCoordinator? overlays;
    private Mutex? instance;
    private bool ownsInstance;
    private bool capturing;
    private bool quitting;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        if (e.Args.Length >= 1 && e.Args[0] == "--recording-smoke-test")
        {
            string directory = Path.GetFullPath(e.Args.Length > 1 ? e.Args[1] : "artifacts");
            try { await RecordingSmokeTest.RunAsync(directory); Shutdown(0); }
            catch (Exception ex) { Directory.CreateDirectory(directory); File.WriteAllText(Path.Combine(directory, "recording-failure.txt"), ex.ToString()); Shutdown(1); }
            return;
        }
        if (e.Args.Length >= 1 && e.Args[0] == "--smoke-test")
        {
            string directory = e.Args.Length > 1 ? e.Args[1] : "artifacts";
            try { SmokeTest.Run(directory); Shutdown(0); }
            catch (Exception ex)
            {
                Console.Error.WriteLine(ex);
                try { Directory.CreateDirectory(directory); File.WriteAllText(Path.Combine(directory, "failure.txt"), ex.ToString()); } catch (IOException) { }
                Shutdown(1);
            }
            return;
        }
        instance = new Mutex(true, "Local\\Slightshot", out ownsInstance);
        if (!ownsInstance) { Shutdown(); return; }
        settings = Settings.Load();
        recording = new RecordingCoordinator(settings);
        trayIcon = CreateTrayIcon();
        tray = new Forms.NotifyIcon { Icon = trayIcon, Text = "Slightshot", Visible = true };
        tray.DoubleClick += (_, _) => Dispatcher.InvokeAsync(BeginCapture);
        output = new OutputService(settings, (title, body) => tray.ShowBalloonTip(3000, title, body, Forms.ToolTipIcon.None));
        overlays = new OverlayCoordinator(settings, output.Perform, SaveCaptureSettings, StartRecording);
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
        menu.Items.Add(new Forms.ToolStripSeparator()); Add(menu, "Quit Slightshot", Quit);
        var old = tray!.ContextMenuStrip; tray.ContextMenuStrip = menu; old?.Dispose();
        if (failures.Length > 0) tray.ShowBalloonTip(6000, "Shortcut unavailable", $"Already in use or invalid: {string.Join(", ", failures)}. Capture from the tray or choose another shortcut in Settings.", Forms.ToolTipIcon.Warning);
    }

    private void Add(Forms.ContextMenuStrip menu, string label, Action action) => menu.Items.Add(label, null, (_, _) => Dispatcher.InvokeAsync(action));
    private void BeginCapture()
    {
        if (capturing || overlays?.IsBusy == true || recording?.IsBusy == true || quitting) return;
        capturing = true;
        try
        {
            preferences?.Hide();
            var displays = ScreenCapture.CaptureAll(settings.CaptureCursor);
            var active = ScreenCapture.UnderPointer(displays);
            overlays!.Present(displays, active);
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException or ArgumentException or OutOfMemoryException) { Dismiss(); Error(ex.Message); }
        finally { capturing = false; }
    }
    private void StartRecording(CapturedDisplay display, RectD selection)
    {
        try { foreach (var window in overlays!.Windows) RecordingWindowExclusion.Exclude(window); }
        catch (System.ComponentModel.Win32Exception error) { Dismiss(); Error(error.Message); return; }
        Dismiss(); recording!.Begin(display, selection);
    }
    private void Dismiss() => overlays?.Dismiss();
    private void SaveCaptureSettings()
    {
        try { settings.Save(); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { Error(ex.Message); }
    }
    private void FullScreen(CaptureAction action)
    {
        if (capturing || overlays?.IsBusy == true || recording?.IsBusy == true || quitting) return;
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
        if (overlays?.IsBusy == true || recording?.IsBusy == true || quitting) return;
        if (preferences == null)
        {
            preferences = new SettingsWindow(settings);
            preferences.Closed += (_, _) => { preferences = null; UpdateSettings(); };
        }
        preferences.Show(); preferences.Activate();
    }
    internal static void Open(string path) => Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
    private async void Quit()
    {
        if (quitting) return;
        quitting = true; Dismiss();
        if (recording != null) await recording.ShutdownAsync();
        Shutdown();
    }
    private static void Error(string text) => MessageBox.Show(text, "Slightshot", MessageBoxButton.OK, MessageBoxImage.Warning);
    private static Icon CreateTrayIcon()
    {
        using var bitmap = new Bitmap(32, 32); using var graphics = Graphics.FromImage(bitmap);
        using var resource = typeof(App).Assembly.GetManifestResourceStream("Slightshot.MenuBarTemplate.png")!;
        using var template = new Bitmap(resource);
        float shade = Appearance.IsDark(taskbar: true) ? 0.92f : 0.12f;
        using var attributes = new System.Drawing.Imaging.ImageAttributes();
        attributes.SetColorMatrix(new System.Drawing.Imaging.ColorMatrix([[0, 0, 0, 0, 0], [0, 0, 0, 0, 0], [0, 0, 0, 0, 0], [0, 0, 0, 1, 0], [shade, shade, shade, 0, 1]]));
        graphics.DrawImage(template, new System.Drawing.Rectangle(0, 0, 32, 32), 0, 0, template.Width, template.Height, GraphicsUnit.Pixel, attributes);
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
