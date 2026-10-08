using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Slightshot.Core;
using Forms = System.Windows.Forms;

namespace Slightshot;

// The actual app windows are driven automatically on the isolated CI desktop.
// Only their HWND bounds are captured, with no fixture illustration or desktop background.
internal static class AppTextSmokeTest
{
    internal static async Task RunAsync(string directory, List<string> checks)
    {
        foreach (bool dark in new[] { false, true })
        {
            var preferences = new SettingsWindow(new Settings { PlaySound = false, DefaultAction = DefaultAction.StayOpen }, dark);
            IntPtr handle = IntPtr.Zero;
            try
            {
                preferences.Show(); preferences.Activate();
                await preferences.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.Loaded);
                await Task.Delay(250);
                handle = new WindowInteropHelper(preferences).Handle;
                var text = Descendants((DependencyObject)preferences.Content).OfType<TextBlock>().Select(block => block.Text).ToArray();
                Require(text.Contains("Return key action") && text.Contains("Double-click inside the selection to use this action."),
                    "General settings displays the action label and double-click instruction");
                var action = Descendants((DependencyObject)preferences.Content).OfType<ComboBox>().Single();
                Require(action.SelectedItem is ComboBoxItem { Content: "Keep editing", Tag: DefaultAction.StayOpen },
                    "General settings displays Keep editing for the StayOpen fixture");
                CaptureWindow(handle, Path.Combine(directory, $"settings-{(dark ? "dark" : "light")}-window.png"));
            }
            finally { preferences.Close(); }
            Require(handle != IntPtr.Zero && !IsWindow(handle), "General settings native window closes after its capture");
        }
        checks.Add("Actual General settings HWNDs shown in light/dark themes with DefaultAction.StayOpen; action label, double-click instruction and Keep editing verified; cropped desktop screenshots saved and windows closed.");

        var app = (App)System.Windows.Application.Current;
        using var menu = app.CreateCaptureMenu();
        var about = menu.Items.OfType<Forms.ToolStripMenuItem>().Single(item => item.Text == "About Slightshot");
        uint processId = (uint)Environment.ProcessId;
        var capture = Task.Run(async () =>
        {
            var timeout = Stopwatch.StartNew();
            IntPtr dialog = IntPtr.Zero;
            try
            {
                while (dialog == IntPtr.Zero && timeout.Elapsed < TimeSpan.FromSeconds(10))
                {
                    dialog = FindAboutDialog(processId);
                    if (dialog == IntPtr.Zero) await Task.Delay(50);
                }
                Require(dialog != IntPtr.Zero, "production About menu opens a native MessageBox within ten seconds");
                await Task.Delay(250);
                var text = new List<string>();
                EnumChildWindows(dialog, (child, _) => { if (ClassName(child) == "Static") text.Add(WindowText(child)); return true; }, IntPtr.Zero);
                Require(text.Any(value => value.Replace("\r\n", "\n") == AppInfo.AboutText),
                    "native About dialog contains the exact production version and app description");
                IntPtr ok = GetDlgItem(dialog, 1);
                Require(ok != IntPtr.Zero && ClassName(ok) == "Button", "native About dialog has an OK button");
                CaptureWindow(dialog, Path.Combine(directory, "about-window.png"));
                Require(PostMessage(ok, 0x00F5, IntPtr.Zero, IntPtr.Zero), "automated click reaches the native About OK button");
                while (IsWindow(dialog) && timeout.Elapsed < TimeSpan.FromSeconds(10)) await Task.Delay(50);
                Require(!IsWindow(dialog), "native About dialog closes after OK within ten seconds");
            }
            finally { if (dialog != IntPtr.Zero && IsWindow(dialog)) PostMessage(dialog, 0x0010, IntPtr.Zero, IntPtr.Zero); }
        });
        // PerformClick uses the production tray route, including its Dispatcher action.
        about.PerformClick();
        await capture;
        checks.Add("Production About tray action opened a real native MessageBox; exact AppInfo.AboutText checked in its Static control; cropped desktop screenshot saved; actual OK button clicked automatically and dialog closure verified.");
    }

    private static void CaptureWindow(IntPtr handle, string path)
    {
        Require(IsWindowVisible(handle) && GetForegroundWindow() == handle, "captured native app window is visible in the foreground");
        Require(RecordingNative.GetWindowRect(handle, out var rect), "captured native app window has bounds");
        var bounds = new System.Drawing.Rectangle(rect.Left, rect.Top, rect.Right - rect.Left, rect.Bottom - rect.Top);
        Require(bounds.Width > 0 && bounds.Height > 0 && Forms.Screen.FromHandle(handle).Bounds.Contains(bounds),
            "captured native window fits entirely on its monitor");
        NativeMethods.DwmFlush();
        using var bitmap = new System.Drawing.Bitmap(bounds.Width, bounds.Height);
        using var graphics = System.Drawing.Graphics.FromImage(bitmap);
        graphics.CopyFromScreen(bounds.Location, System.Drawing.Point.Empty, bounds.Size);
        bitmap.Save(path, System.Drawing.Imaging.ImageFormat.Png);
    }

    private static IntPtr FindAboutDialog(uint processId)
    {
        IntPtr result = IntPtr.Zero;
        EnumWindows((handle, _) =>
        {
            GetWindowThreadProcessId(handle, out uint owner);
            if (owner == processId && IsWindowVisible(handle) && ClassName(handle) == "#32770" && WindowText(handle) == "About Slightshot")
            { result = handle; return false; }
            return true;
        }, IntPtr.Zero);
        return result;
    }
    private static string WindowText(IntPtr handle) { var text = new StringBuilder(8192); GetWindowText(handle, text, text.Capacity); return text.ToString(); }
    private static string ClassName(IntPtr handle) { var text = new StringBuilder(128); GetClassName(handle, text, text.Capacity); return text.ToString(); }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
    {
        for (int index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
        {
            var child = VisualTreeHelper.GetChild(parent, index); yield return child;
            foreach (var descendant in Descendants(child)) yield return descendant;
        }
    }
    private static void Require(bool condition, string check) { if (!condition) throw new InvalidOperationException($"App text smoke test failed: {check}"); }
    private delegate bool WindowCallback(IntPtr handle, IntPtr data);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool EnumWindows(WindowCallback callback, IntPtr data);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool EnumChildWindows(IntPtr parent, WindowCallback callback, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr handle, StringBuilder text, int capacity);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr handle, StringBuilder text, int capacity);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr handle, out uint processId);
    [DllImport("user32.dll")] private static extern IntPtr GetDlgItem(IntPtr dialog, int id);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindow(IntPtr handle);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindowVisible(IntPtr handle);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool PostMessage(IntPtr handle, uint message, IntPtr wParam, IntPtr lParam);
}
