using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Slightshot.Core;

namespace Slightshot;

internal sealed class RecordingPanel : Window
{
    private readonly TextBlock elapsed = new() { Text = "Starting…", Foreground = Brushes.White, FontFamily = new FontFamily("Consolas"), FontSize = 12, Width = 72, TextAlignment = TextAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private readonly ToolbarButton stop;
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(500) };
    internal RecordingPanel(CapturedDisplay display, RectD selection, Action onStop)
    {
        // Per-pixel WPF transparency uses UpdateLayeredWindow, which conflicts
        // with display affinity on supported Windows 10 versions. Use an opaque
        // native window region for the same rounded HUD shape instead.
        Title = "Screen recording"; WindowStyle = WindowStyle.None; Background = Appearance.Brush("#17171A");
        Width = 112; Height = 38; ResizeMode = ResizeMode.NoResize; ShowInTaskbar = false; Topmost = true; ShowActivated = false;
        stop = new ToolbarButton(ProductIcon.Stop, "Stop recording", onStop) { IsEnabled = false, Selected = true };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(4) };
        row.Children.Add(elapsed); elapsed.Margin = new Thickness(0, 0, 2, 0); row.Children.Add(stop);
        Content = new FrostedPanel(row);
        double x = OverlayStyle.Fit(selection.Right - Width, Width, display.Width);
        double y = selection.Bottom + 8;
        if (y + Height > display.Height - 4) y = selection.Top - Height - 8;
        y = OverlayStyle.Fit(y, Height, display.Height);
        Left = (display.Left + x * display.Scale) / display.Scale; Top = (display.Top + y * display.Scale) / display.Scale;
        SourceInitialized += (_, _) =>
        {
            RecordingWindowExclusion.Exclude(this);
            NativeMethods.SetWindowPos(new WindowInteropHelper(this).Handle, new IntPtr(-1), display.Left + (int)Math.Round(x * display.Scale), display.Top + (int)Math.Round(y * display.Scale), (int)Math.Round(Width * display.Scale), (int)Math.Round(Height * display.Scale), 0x0050);
            RecordingWindowExclusion.RoundCorners(this, 9);
        };
        SizeChanged += (_, _) => RecordingWindowExclusion.RoundCorners(this, 9);
        DpiChanged += (_, _) => RecordingWindowExclusion.RoundCorners(this, 9);
        MouseLeftButtonDown += (_, e) => { if (e.OriginalSource is not Button) DragMove(); };
        Closed += (_, _) => timer.Stop();
    }
    internal void Started(Func<TimeSpan> duration)
    {
        stop.IsEnabled = true;
        void Update() { TimeSpan time = duration(); elapsed.Text = $"{(int)time.TotalMinutes:00}:{time.Seconds:00}"; }
        timer.Tick += (_, _) => Update(); Update(); timer.Start();
    }
}

// Save-time quality shares the three Mac choices. File name and folder stay in
// the same compact dialog, with the configured screenshot folder as default.
internal sealed class RecordingSaveWindow : Window
{
    private readonly TextBox filename;
    private readonly TextBlock folder;
    private readonly Slider quality;
    internal string Destination => Path.Combine(folder.Text, filename.Text.EndsWith(".mp4", StringComparison.OrdinalIgnoreCase) ? filename.Text : filename.Text + ".mp4");
    internal RecordingQuality Quality => (RecordingQuality)(int)Math.Round(quality.Value);
    internal RecordingSaveWindow(Settings settings, int width, int height, string? proposed, bool? forceDark = null)
    {
        Title = "Save recording"; Width = 440; SizeToContent = SizeToContent.Height; ResizeMode = ResizeMode.NoResize; WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Appearance.ApplyWindowTheme(this, forceDark);
        var column = new StackPanel { Margin = new Thickness(20) };
        filename = new TextBox { Text = proposed != null ? Path.GetFileName(proposed) : OutputNaming.FileName(settings.FilenameTemplate == "Screenshot {date} at {time}" ? "Recording {date} at {time}" : settings.FilenameTemplate, DateTimeOffset.Now, width, height) + ".mp4", Margin = new Thickness(0, 4, 0, 12) };
        column.Children.Add(new TextBlock { Text = "File name" }); column.Children.Add(filename);
        folder = new TextBlock { Text = proposed != null ? Path.GetDirectoryName(proposed)! : settings.SaveDirectory, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
        var directory = new Grid { Margin = new Thickness(0, 0, 0, 16) };
        directory.ColumnDefinitions.Add(new ColumnDefinition()); directory.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        directory.Children.Add(folder);
        var choose = new Button { Content = "Choose…", Padding = new Thickness(10, 3, 10, 3), Margin = new Thickness(8, 0, 0, 0) }; Grid.SetColumn(choose, 1); directory.Children.Add(choose);
        choose.Click += (_, _) => { using var dialog = new System.Windows.Forms.FolderBrowserDialog { InitialDirectory = folder.Text, Description = "Save recordings to", UseDescriptionForTitle = true }; if (dialog.ShowDialog() == System.Windows.Forms.DialogResult.OK) folder.Text = dialog.SelectedPath; };
        column.Children.Add(directory);
        var title = new TextBlock { FontWeight = FontWeights.SemiBold };
        var details = new TextBlock { FontSize = 11, Foreground = (Brush)Resources["SecondaryBrush"], Margin = new Thickness(0, 6, 0, 14) };
        quality = new Slider { Minimum = 0, Maximum = 2, TickFrequency = 1, SmallChange = 1, LargeChange = 1, IsSnapToTickEnabled = true, IsMoveToPointEnabled = true, TickPlacement = System.Windows.Controls.Primitives.TickPlacement.BottomRight, Value = (int)settings.RecordingQuality, Margin = new Thickness(0, 5, 0, 0) };
        System.Windows.Automation.AutomationProperties.SetName(quality, "Recording compression quality");
        void Update() { title.Text = Quality.Title(); details.Text = Quality.Detail(width, height); }
        quality.ValueChanged += (_, _) => Update(); Update();
        column.Children.Add(title); column.Children.Add(quality);
        var labels = new Grid(); labels.Children.Add(new TextBlock { Text = "Small & fast", FontSize = 11 }); labels.Children.Add(new TextBlock { Text = "High quality", FontSize = 11, HorizontalAlignment = HorizontalAlignment.Right }); column.Children.Add(labels); column.Children.Add(details);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        var cancel = new Button { Content = "Cancel", IsCancel = true, Padding = new Thickness(14, 4, 14, 4), Margin = new Thickness(0, 0, 8, 0) };
        var save = new Button { Content = "Save", IsDefault = true, Padding = new Thickness(14, 4, 14, 4) };
        save.Click += (_, _) =>
        {
            if (string.IsNullOrWhiteSpace(filename.Text) || filename.Text.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || string.IsNullOrWhiteSpace(folder.Text)) { MessageBox.Show(this, "Choose a valid file name and folder.", "Save recording"); return; }
            if (File.Exists(Destination) && MessageBox.Show(this, "Replace the existing recording?", "Save recording", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
            DialogResult = true;
        };
        buttons.Children.Add(cancel); buttons.Children.Add(save); column.Children.Add(buttons); Content = column;
        SourceInitialized += (_, _) => RecordingWindowExclusion.Exclude(this);
        Loaded += (_, _) => { filename.Focus(); filename.Select(0, Path.GetFileNameWithoutExtension(filename.Text).Length); };
    }
}

internal sealed class RecordingProgressWindow : Window
{
    private readonly ProgressBar progress = new() { Minimum = 0, Maximum = 100, IsIndeterminate = true, Height = 8 };
    internal RecordingProgressWindow(Action cancel)
    {
        Title = "Saving recording…"; Width = 320; Height = 140; ResizeMode = ResizeMode.NoResize; WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Appearance.ApplyWindowTheme(this);
        var column = new StackPanel { Margin = new Thickness(20) }; column.Children.Add(progress);
        var button = new Button { Content = "Cancel", IsCancel = true, Padding = new Thickness(14, 4, 14, 4), HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 14, 0, 0) };
        button.Click += (_, _) => cancel(); column.Children.Add(button); Content = column;
        Closing += (_, _) => cancel();
        SourceInitialized += (_, _) => RecordingWindowExclusion.Exclude(this);
    }
    internal void Update(double value) { progress.IsIndeterminate = false; progress.Value = value; }
}
