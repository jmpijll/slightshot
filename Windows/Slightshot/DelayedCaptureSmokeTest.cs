using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Slightshot.Core;
using Forms = System.Windows.Forms;

namespace Slightshot;

// This bounded fixture drives the production menu, controller, real GDI
// capture and real editor. Screenshots are pixels from the composed desktop.
internal static class DelayedCaptureSmokeTest
{
    internal static async Task RunAsync(App app, string directory)
    {
        Directory.CreateDirectory(directory);
        var checks = new List<string>();
        var settings = new Settings { CaptureCursor = false, PlaySound = false, ShowNotification = false };
        var overlays = new OverlayCoordinator(settings, (_, _) => true, () => { }, (_, _) => { });
        Set(app, "settings", settings); Set(app, "overlays", overlays);
        Invoke(app, "ConfigureDelayedCapture");
        var delayed = Get<DelayedCaptureController>(app, "delayedCapture");
        var label = new TextBlock { Text = "Before the five-second deadline", FontSize = 26, Foreground = Brushes.White, Margin = new Thickness(40) };
        var target = new Window { Title = "Delayed capture acceptance source", Width = 720, Height = 360, Left = 60, Top = 60,
            Background = Brushes.DarkRed, Content = label };
        target.Show(); target.Activate();
        await Task.Delay(300);
        using var menu = app.CreateCaptureMenu();
        menu.Show(100, 120);
        await Task.Delay(300);
        SaveDesktop(directory, "windows-menu.png");
        menu.Close(); target.Activate();
        IntPtr foreground = GetForegroundWindow();
        var action = menu.Items.OfType<Forms.ToolStripMenuItem>().Single(item => item.Text == "Capture Area in 5 Seconds");
        var watch = Stopwatch.StartNew(); action.PerformClick();
        await Task.Delay(700);
        Require(delayed.IsPending && !overlays.IsBusy, "menu schedules without freezing the screenshot");
        var panel = Get<DelayedCapturePanel>(app, "countdownPanel");
        Require(panel.IsVisible && GetForegroundWindow() == foreground, "visible countdown preserves target keyboard focus");
        Require((RecordingNative.GetWindowLong(new WindowInteropHelper(panel).Handle, -20) & 0x08000000) != 0,
            "countdown uses native WS_EX_NOACTIVATE");
        SaveDesktop(directory, "windows-countdown.png");
        label.Text = "Screen content at the five-second deadline";
        target.Background = Brushes.SeaGreen;
        await Task.Delay(300);
        // No editor may exist before the real wall-clock deadline.
        while (watch.Elapsed.TotalSeconds < 4.9) { Require(!overlays.IsBusy, "no early editor"); await Task.Delay(100); }
        while (!overlays.IsBusy && watch.Elapsed.TotalSeconds < 10) await Task.Delay(50);
        Require(overlays.IsBusy && watch.Elapsed.TotalSeconds >= 5, "real production capture opens after five seconds");
        Require(!delayed.IsPending && !panel.IsVisible, "deadline closes countdown before GDI sampling");
        var editor = overlays.Windows[0];
        var field = typeof(OverlayWindow).GetField("display", BindingFlags.Instance | BindingFlags.NonPublic)!;
        var display = (CapturedDisplay)field.GetValue(editor)!;
        // Check a clear region of the native target window changed AFTER scheduling.
        var point = target.PointToScreen(new Point(650, 250));
        int x = (int)point.X - display.Left, y = (int)point.Y - display.Top;
        Require(x >= 0 && y >= 0 && x < display.PixelWidth && y < display.PixelHeight, "live target is on captured monitor");
        byte[] pixel = new byte[4];
        new FormatConvertedBitmap(display.Image, PixelFormats.Bgra32, null, 0).CopyPixels(new Int32Rect(x, y, 1, 1), pixel, 4, 0);
        Require(pixel[1] > pixel[2] && pixel[1] > pixel[0], "frozen screenshot contains later green content, not initial red content");
        editor.PrepareSmokeFixture(new RectD(60, 60, 720, 360), []);
        await Task.Delay(250);
        SaveDesktop(directory, "windows-result.png");
        action.PerformClick(); await Task.Delay(100);
        Require(!delayed.IsPending && overlays.Windows.Contains(editor), "active real editor rejects a delayed request");
        overlays.Dismiss();
        action.PerformClick(); await Task.Delay(100);
        panel = Get<DelayedCapturePanel>(app, "countdownPanel");
        var cancel = ((StackPanel)panel.Content).Children.OfType<Button>().Single();
        cancel.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Require(!delayed.IsPending && !panel.IsVisible, "real Cancel button releases pending countdown");
        await Task.Delay(5300);
        Require(!overlays.IsBusy, "cancelled countdown never opens a late editor");
        action.PerformClick(); await Task.Delay(100);
        Require(delayed.IsPending, "ordinary capture fixture has a pending countdown");
        Invoke(app, "BeginCapture");
        Require(!delayed.IsPending && overlays.IsBusy, "ordinary capture cancels pending timer and opens editor immediately");
        overlays.Dismiss(); await Task.Delay(5300);
        Require(!overlays.IsBusy, "ordinary capture's replaced timer never opens another editor");
        checks.Add("Production menu started a fixed five-second countdown with target focus unchanged; native nonactivation style checked. No early editor opened. The real GDI screenshot retained target pixels changed from red to green after scheduling, then the real area editor appeared. Active editor rejected a new timer. The real Cancel button prevented a later editor. An ordinary capture cancelled its pending timer, opened immediately, and never opened a second editor.");
        target.Close(); delayed.Cancel();
        File.WriteAllText(Path.Combine(directory, "delayed-capture-validation.json"), JsonSerializer.Serialize(new
        {
            platform = "Windows Forms tray menu / native WPF HUD and editor / GDI desktop capture",
            source = "Automated bounded native desktop acceptance fixture. Production menu/controller/capture/editor with a real WPF target window; screenshots sampled from the composed CI desktop, not mockups.",
            sourceCommit = Environment.GetEnvironmentVariable("GITHUB_SHA") ?? "local",
            elapsedSeconds = watch.Elapsed.TotalSeconds, checks
        }, new JsonSerializerOptions { WriteIndented = true }));
    }

    private static void SaveDesktop(string directory, string name)
    {
        NativeMethods.DwmFlush();
        var display = ScreenCapture.UnderPointer(ScreenCapture.CaptureAll(false));
        using var file = File.Create(Path.Combine(directory, name)); OutputService.Encode(display.Image, ImageFormat.Png, 1).Save(file);
    }
    private static T Get<T>(App app, string name) => (T)typeof(App).GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(app)!;
    private static void Set(App app, string name, object value) => typeof(App).GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(app, value);
    private static void Invoke(App app, string name) => typeof(App).GetMethod(name, BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(app, null);
    private static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException("Delayed capture smoke test: " + message); }
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
}
