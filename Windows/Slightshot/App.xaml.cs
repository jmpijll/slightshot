using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Windows;
using System.Windows.Threading;
using Slightshot.Core;
using Forms = System.Windows.Forms;

namespace Slightshot;

public partial class App : System.Windows.Application
{
    internal const string InstanceMutexName = "Local\\Slightshot";
    private static readonly string DataDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Slightshot");
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
    private InstanceChannel? commands;
    private HotKey[] unavailable = [];
    private Action? balloonClicked;
    private bool reportingError;
    private bool started;
    private bool capturing;
    private bool quitting;
    private DelayedCaptureController? delayedCapture;
    private DelayedCapturePanel? countdownPanel;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        if (e.Args.Length >= 1 && e.Args[0] == "--shortcut-smoke-test")
        {
            string directory = Path.GetFullPath(e.Args.Length > 1 ? e.Args[1] : "artifacts");
            try { await ShortcutSmokeTest.RunAsync(directory); Shutdown(0); }
            catch (Exception ex) { Directory.CreateDirectory(directory); File.WriteAllText(Path.Combine(directory, "shortcut-failure.txt"), ex.ToString()); Shutdown(1); }
            return;
        }
        if (e.Args.Length >= 1 && e.Args[0] == "--instance-smoke-test")
        {
            string directory = Path.GetFullPath(e.Args.Length > 1 ? e.Args[1] : "artifacts");
            try { await InstanceSmokeTest.RunAsync(this, directory); Shutdown(0); }
            catch (Exception ex) { Directory.CreateDirectory(directory); File.WriteAllText(Path.Combine(directory, "instance-failure.txt"), ex.ToString()); Shutdown(1); }
            return;
        }
        if (e.Args.Length >= 1 && e.Args[0] == "--clipboard-smoke-test")
        {
            string directory = Path.GetFullPath(e.Args.Length > 1 ? e.Args[1] : "artifacts");
            try { await ClipboardEditorSmokeTest.RunAsync(directory); Shutdown(0); }
            catch (Exception ex) { Directory.CreateDirectory(directory); File.WriteAllText(Path.Combine(directory, "clipboard-failure.txt"), ex.ToString()); Shutdown(1); }
            return;
        }
        if (e.Args.Length >= 1 && e.Args[0] == "--delayed-capture-smoke-test")
        {
            string directory = Path.GetFullPath(e.Args.Length > 1 ? e.Args[1] : "artifacts");
            try { await DelayedCaptureSmokeTest.RunAsync(this, directory); Shutdown(0); }
            catch (Exception ex) { Directory.CreateDirectory(directory); File.WriteAllText(Path.Combine(directory, "delayed-capture-failure.txt"), ex.ToString()); Shutdown(1); }

            return;
        }
        if (e.Args.Length >= 1 && e.Args[0] == "--video-editor-4k-benchmark")
        {
            string directory = Path.GetFullPath(e.Args.Length > 1 ? e.Args[1] : "artifacts");
            try { await VideoEditor4KBenchmark.RunAsync(directory); Shutdown(0); }
            catch (Exception ex) { Directory.CreateDirectory(directory); File.WriteAllText(Path.Combine(directory, "video-editor-4k-failure.txt"), ex.ToString()); Shutdown(1); }
            return;
        }
        if (e.Args.Length >= 1 && e.Args[0] == "--video-editor-smoke-test")
        {
            string directory = Path.GetFullPath(e.Args.Length > 1 ? e.Args[1] : "artifacts");
            try { await VideoEditorSmokeTest.RunAsync(directory); Shutdown(0); }
            catch (Exception ex) { Directory.CreateDirectory(directory); File.WriteAllText(Path.Combine(directory, "video-editor-failure.txt"), ex.ToString()); Shutdown(1); }
            return;
        }
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
            try { await SmokeTest.RunAsync(directory); Shutdown(0); }
            catch (Exception ex)
            {
                Console.Error.WriteLine(ex);
                try { Directory.CreateDirectory(directory); File.WriteAllText(Path.Combine(directory, "failure.txt"), ex.ToString()); } catch (IOException) { }
                Shutdown(1);
            }
            return;
        }
        InstallErrorHandlers(Path.Combine(DataDirectory, "Logs"), Error, () => started);
        bool known = LaunchArguments.TryParse(e.Args, out var command);
        instance = new Mutex(true, InstanceMutexName, out ownsInstance);
        if (!ownsInstance)
        {
            if (!known) { Shutdown(2); return; }
            bool forwarded = await InstanceChannel.SendAsync(InstancePipeName(), command ?? LaunchCommand.CaptureArea, TimeSpan.FromSeconds(5));
            if (!forwarded) Error("Slightshot is already running but did not respond. Use its icon in the notification area, or quit it and start Slightshot again.");
            Shutdown(forwarded ? 0 : 1); return;
        }
        bool firstRun = !Directory.Exists(DataDirectory);
        settings = Settings.Load(out string? settingsNotice);
        recording = new RecordingCoordinator(settings);
        trayIcon = CreateTrayIcon();
        tray = new Forms.NotifyIcon { Icon = trayIcon, Text = "Slightshot", Visible = true };
        tray.DoubleClick += (_, _) => Dispatcher.InvokeAsync(BeginCapture);
        tray.BalloonTipClicked += (_, _) => { var clicked = balloonClicked; balloonClicked = null; if (clicked != null) Dispatcher.InvokeAsync(clicked); };
        output = new OutputService(settings, (title, body) => ShowBalloon(3000, title, body, Forms.ToolTipIcon.None));
        overlays = new OverlayCoordinator(settings, output.Perform, SaveCaptureSettings, StartRecording);
        ConfigureDelayedCapture();
        hotKeys = new HotKeyService(id => Dispatcher.InvokeAsync(() => { if (id == 1) BeginCapture(); else FullScreen(id == 2 ? CaptureAction.Save : CaptureAction.Copy); }));
        UpdateSettings();
        commands = new InstanceChannel(InstancePipeName(), IsSameSessionClient, received => Dispatcher.InvokeAsync(() => Run(received)));
        if (settingsNotice != null) ShowBalloon(8000, "Settings reset", settingsNotice, Forms.ToolTipIcon.Warning);
        else if (firstRun && unavailable.Length == 0)
            ShowBalloon(8000, "Slightshot is running", settings.CaptureAreaHotKey.IsEmpty
                ? "Double-click the Slightshot icon in the notification area to capture an area."
                : $"Press {settings.CaptureAreaHotKey} to capture an area, or use the Slightshot icon in the notification area.", Forms.ToolTipIcon.Info);
        started = true;
        if (command is { } initial) _ = Dispatcher.InvokeAsync(() => Run(initial));
    }

    internal static string InstancePipeName()
    {
        using var identity = WindowsIdentity.GetCurrent();
        using var process = Process.GetCurrentProcess();
        return $"Slightshot-{identity.User?.Value}-{process.SessionId}";
    }

    // The pipe admits only this user; also refuse that user's processes in other logon sessions.
    internal static bool IsSameSessionClient(NamedPipeServerStream pipe)
    {
        using var process = Process.GetCurrentProcess();
        return GetNamedPipeClientSessionId(pipe.SafePipeHandle, out uint session) && session == (uint)process.SessionId;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeClientSessionId(Microsoft.Win32.SafeHandles.SafePipeHandle pipe, out uint session);

    private void Run(LaunchCommand command)
    {
        if (command == LaunchCommand.CaptureArea) BeginCapture();
        else FullScreen(command == LaunchCommand.SaveFullScreen ? CaptureAction.Save : CaptureAction.Copy);
    }

    private void UpdateSettings()
    {
        try { settings.Save(); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { Error($"Could not save settings.\n\n{ex.Message}"); }
        unavailable = hotKeys!.Register(settings);
        var menu = CreateCaptureMenu();
        var old = tray!.ContextMenuStrip; tray.ContextMenuStrip = menu; old?.Dispose();
        if (unavailable.Length > 0)
            ShowBalloon(6000, "Shortcut unavailable", $"Already in use or invalid: {string.Join(", ", unavailable)}."
                + (unavailable.Any(key => key.IsPrintScreen) && HotKeyService.WindowsUsesPrintScreen() ? " Windows is using Print Screen to open screen capture." : "")
                + " Click to choose another shortcut in Settings.", Forms.ToolTipIcon.Warning, ShowSettings);
    }

    private void ShowBalloon(int timeout, string title, string body, Forms.ToolTipIcon icon, Action? clicked = null)
    {
        balloonClicked = clicked;
        tray!.ShowBalloonTip(timeout, title, body, icon);
    }

    internal void InstallErrorHandlers(string logDirectory, Action<string> report, Func<bool> canRecover)
    {
        DispatcherUnhandledException += (_, e) =>
        {
            e.Handled = true;
            string? log = LogError(logDirectory, "UI thread", e.Exception);
            // Before startup completes the tray, hotkeys and command listener may
            // be half built, so report and exit rather than resume.
            bool recover = canRecover();
            if (recover)
            {
                try { delayedCapture?.Cancel(); Dismiss(); }
                catch (Exception ex) { LogError(logDirectory, "Closing the capture after an error", ex); }
                capturing = false;
            }
            // A message box pumps the dispatcher, so errors raised while it is
            // open are logged without stacking further messages.
            if (!reportingError)
            {
                reportingError = true;
                string details = log == null ? "" : $"\n\nDetails were saved to {log}.";
                try { report((recover ? "Slightshot ran into a problem and closed the capture. It is still running in the notification area." : "Slightshot ran into a problem and could not start.") + details); }
                finally { reportingError = false; }
            }
            if (!recover) Shutdown(1);
        };
        AppDomain.CurrentDomain.UnhandledException += (_, e) => LogError(logDirectory, "Unhandled exception",
            e.ExceptionObject as Exception ?? new InvalidOperationException(e.ExceptionObject?.ToString()));
        TaskScheduler.UnobservedTaskException += (_, e) => { LogError(logDirectory, "Unobserved task exception", e.Exception); e.SetObserved(); };
    }

    private static string? LogError(string directory, string source, Exception error)
    {
        try { return ErrorLog.Append(directory, source, error, DateTimeOffset.Now); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return null; }
    }

    internal Forms.ContextMenuStrip CreateCaptureMenu()
    {
        var menu = new Forms.ContextMenuStrip();
        Add(menu, $"Capture Area    {settings.CaptureAreaHotKey}", BeginCapture);
        Add(menu, "Capture Area in 5 Seconds", () => delayedCapture?.Start());
        Add(menu, $"Capture Full Screen    {settings.SaveFullScreenHotKey}", () => FullScreen(CaptureAction.Save));
        Add(menu, $"Copy Full Screen    {settings.CopyFullScreenHotKey}", () => FullScreen(CaptureAction.Copy));
        Add(menu, "Edit Image from Clipboard", EditClipboard);
        menu.Items.Add(new Forms.ToolStripSeparator());
        Add(menu, "Open Screenshots Folder", () => { try { Directory.CreateDirectory(settings.SaveDirectory); Open(settings.SaveDirectory); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { Error(ex.Message); } });
        menu.Items.Add(new Forms.ToolStripSeparator());
        Add(menu, "Settings…", ShowSettings);
        Add(menu, "Check for Updates…", () => _ = UpdateCheck.RunAsync(preferences));
        Add(menu, "About Slightshot", () => MessageBox.Show(AppInfo.AboutText, "About Slightshot", MessageBoxButton.OK));
        menu.Items.Add(new Forms.ToolStripSeparator()); Add(menu, "Quit Slightshot", Quit);
        return menu;
    }

    private void Add(Forms.ContextMenuStrip menu, string label, Action action) => menu.Items.Add(label, null, (_, _) => Dispatcher.InvokeAsync(action));
    private void BeginCapture()
    {
        delayedCapture?.Cancel();
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
    private void EditClipboard()
    {
        delayedCapture?.Cancel();
        if (capturing || overlays?.IsBusy == true || recording?.IsBusy == true || quitting) return;
        capturing = true;
        try
        {
            var bitmap = ClipboardImage.Read();
            if (bitmap == null) { Error("The clipboard does not contain an image. Copy an image and try again."); return; }
            preferences?.Hide();
            overlays!.PresentClipboardImage(bitmap);
        }
        catch (Exception ex) when (ex is System.Runtime.InteropServices.ExternalException or IOException or InvalidOperationException or ArgumentException or NotSupportedException or OutOfMemoryException) { Dismiss(); Error(ex.Message); }
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
        delayedCapture?.Cancel();
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
        if (overlays?.IsDelivering == true || recording?.IsBusy == true || quitting) return;
        if (overlays?.IsBusy == true) Dismiss();
        if (preferences == null)
        {
            preferences = new SettingsWindow(settings, null, unavailable);
            preferences.Closed += (_, _) => { preferences = null; UpdateSettings(); };
        }
        preferences.Show(); preferences.Activate();
    }
    internal static void Open(string path) => Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
    private async void Quit()
    {
        if (quitting) return;
        quitting = true; Dismiss();
        delayedCapture?.Cancel();
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
        delayedCapture?.Cancel();
        commands?.Dispose(); hotKeys?.Dispose(); tray?.Dispose(); trayIcon?.Dispose();
        if (ownsInstance) instance?.ReleaseMutex(); instance?.Dispose(); base.OnExit(e);
    }

    private void ConfigureDelayedCapture()
    {
        delayedCapture = new DelayedCaptureController(() => (double)Stopwatch.GetTimestamp() / Stopwatch.Frequency,
            ScheduleCountdown, () => capturing || overlays?.IsBusy == true || recording?.IsBusy == true || quitting,
            seconds =>
            {
                if (countdownPanel == null)
                {
                    countdownPanel = new DelayedCapturePanel(() => delayedCapture?.Cancel());
                    countdownPanel.Show();
                }
                countdownPanel.Update(seconds);
            }, () =>
            {
                if (countdownPanel == null) return;
                countdownPanel.Close(); countdownPanel = null;
                // Cancel is also used by ordinary capture shortcuts. Flush here
                // so every path samples restored target pixels beneath the HUD.
                NativeMethods.DwmFlush();
            }, () =>
            {
                // Remove an open tray menu and wait for desktop composition so
                // the screenshot contains neither the countdown nor our menu.
                tray?.ContextMenuStrip?.Close();
                NativeMethods.DwmFlush();
                BeginCapture();
            });
    }

    private Action ScheduleCountdown(double seconds, Action callback)
    {
        var timer = new DispatcherTimer(DispatcherPriority.Normal, Dispatcher) { Interval = TimeSpan.FromSeconds(seconds) };
        timer.Tick += (_, _) => { timer.Stop(); callback(); };
        timer.Start();
        return timer.Stop;
    }
}
