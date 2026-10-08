using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using Forms = System.Windows.Forms;

namespace Slightshot;

internal sealed class DelayedCapturePanel : Window
{
    private readonly TextBlock label = new() { Text = "Capture in 5…", Foreground = Brushes.White,
        FontSize = 13, FontFamily = new FontFamily("Consolas"), Width = 130, VerticalAlignment = VerticalAlignment.Center };
    internal DelayedCapturePanel(Action cancel)
    {
        Title = "Delayed screenshot"; WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
        Width = 250; Height = 52; Background = Appearance.Brush("#17171A");
        ShowInTaskbar = false; Topmost = true; ShowActivated = false;
        var button = new Button { Content = "Cancel", Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(12, 0, 0, 0) };
        AutomationProperties.SetName(button, "Cancel delayed capture");
        button.Click += (_, _) => cancel();
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(label); row.Children.Add(button); Content = row;
        NativeMethods.GetCursorPos(out var pointer);
        var monitor = Forms.Screen.FromPoint(new System.Drawing.Point(pointer.X, pointer.Y));
        var bounds = monitor.WorkingArea;
        double scale = 1;
        NativeMethods.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr handle, IntPtr dc, ref NativeMethods.NativeRect rect, IntPtr data) =>
        {
            if (pointer.X >= rect.Left && pointer.X < rect.Right && pointer.Y >= rect.Top && pointer.Y < rect.Bottom)
            {
                NativeMethods.GetDpiForMonitor(handle, 0, out uint dpi, out _);
                scale = (dpi == 0 ? 96 : dpi) / 96.0;
            }
            return true;
        }, IntPtr.Zero);
        int x = bounds.Left + (bounds.Width - (int)Math.Round(Width * scale)) / 2;
        int y = bounds.Bottom - (int)Math.Round((Height + 24) * scale);
        Left = x / scale; Top = y / scale;
        SourceInitialized += (_, _) =>
        {
            IntPtr handle = new WindowInteropHelper(this).Handle;
            RecordingNative.SetWindowLong(handle, -20, RecordingNative.GetWindowLong(handle, -20) | 0x08000000); // WS_EX_NOACTIVATE
            NativeMethods.SetWindowPos(handle, new IntPtr(-1), x, y, (int)Math.Round(Width * scale), (int)Math.Round(Height * scale), 0x0050);
            RecordingWindowExclusion.RoundCorners(this, 10);
        };
        DpiChanged += (_, _) => RecordingWindowExclusion.RoundCorners(this, 10);
    }
    internal void Update(int seconds) => label.Text = $"Capture in {seconds}…";
}
