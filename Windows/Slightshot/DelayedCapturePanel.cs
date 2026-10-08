using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;

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
        var bounds = SystemParameters.WorkArea;
        Left = bounds.Left + (bounds.Width - Width) / 2; Top = bounds.Bottom - Height - 24;
        SourceInitialized += (_, _) =>
        {
            IntPtr handle = new WindowInteropHelper(this).Handle;
            RecordingNative.SetWindowLong(handle, -20, RecordingNative.GetWindowLong(handle, -20) | 0x08000000); // WS_EX_NOACTIVATE
            RecordingWindowExclusion.RoundCorners(this, 10);
        };
    }
    internal void Update(int seconds) => label.Text = $"Capture in {seconds}…";
}
