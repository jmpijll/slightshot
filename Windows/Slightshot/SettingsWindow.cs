using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;
using Slightshot.Core;

namespace Slightshot;

internal sealed class SettingsWindow : Window
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private readonly Settings settings;
    public SettingsWindow(Settings settings)
    {
        this.settings = settings;
        Title = "Slightshot Settings"; Width = 560; Height = 620; ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = new FontFamily("Segoe UI"); FontSize = 13; Background = new SolidColorBrush(Color.FromRgb(243, 243, 245));
        var tabs = new TabControl { Margin = new Thickness(12, 16, 12, 12) };
        tabs.Items.Add(Tab("General", General())); tabs.Items.Add(Tab("Shortcuts", Shortcuts())); tabs.Items.Add(Tab("Output", Output())); tabs.Items.Add(Tab("Capture", Capture()));
        Content = tabs;
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape && e.OriginalSource is not TextBox) Close(); };
    }
    private UIElement General()
    {
        var panel = Column();
        bool atLogin;
        using (var run = Registry.CurrentUser.OpenSubKey(RunKey)) atLogin = run?.GetValue("Slightshot") is string;
        var login = Check("Launch Slightshot at login", atLogin, enabled =>
        {
            try
            {
                using var key = Registry.CurrentUser.CreateSubKey(RunKey);
                if (enabled) key.SetValue("Slightshot", $"\"{Environment.ProcessPath}\""); else key.DeleteValue("Slightshot", false);
            }
            catch (Exception ex) when (ex is UnauthorizedAccessException or IOException or System.Security.SecurityException) { MessageBox.Show(ex.Message, "Slightshot"); }
        });
        panel.Children.Add(Group(null, login, Check("Play a shutter sound", settings.PlaySound, v => settings.PlaySound = v), Check("Show a notification after saving", settings.ShowNotification, v => settings.ShowNotification = v)));
        panel.Children.Add(Group(null, Row("When you press Return:", Combo(Enum.GetValues<DefaultAction>(), settings.DefaultAction, v => settings.DefaultAction = v, v => v switch { DefaultAction.Copy => "Copy to clipboard", DefaultAction.Save => "Save to file", _ => "Do nothing (keep editing)" })), Help("Double-clicking inside the selection does the same thing.")));
        var source = new Button { Content = "Source on GitHub", HorizontalAlignment = HorizontalAlignment.Left, Padding = new Thickness(8, 4, 8, 4) }; source.Click += (_, _) => App.Open("https://github.com/jmpijll/slightshot");
        panel.Children.Add(Group(null, Row("Version", new TextBlock { Text = "0.1.0 · Windows" }), source, Help("Windows updates are installed from GitHub releases.")));
        return panel;
    }
    private UIElement Shortcuts()
    {
        var panel = Column();
        panel.Children.Add(Group("Global shortcuts", Row("Capture area", Shortcut(() => settings.CaptureAreaHotKey, v => settings.CaptureAreaHotKey = v)), Row("Capture full screen", Shortcut(() => settings.SaveFullScreenHotKey, v => settings.SaveFullScreenHotKey = v)), Row("Copy full screen", Shortcut(() => settings.CopyFullScreenHotKey, v => settings.CopyFullScreenHotKey = v)), Help("Click a field, then press the combination. Escape clears it.\nChanges take effect when Settings closes.")));
        (string Shortcut, string Description)[] shortcuts = [("Ctrl+A", "Select the whole screen"), ("Ctrl+C", "Copy to clipboard"), ("Ctrl+S", "Save to file"), ("Ctrl+Shift+S", "Save as…"), ("Ctrl+P", "Print"), ("Ctrl+Z", "Undo the last annotation"), ("Enter", "Confirm"), ("Esc", "Cancel"), ("Shift+drag", "Constrain to a square or 45°"), ("Ctrl+drag", "Select and copy in one motion"), ("↑↓←→", "Nudge the selection by one point"), ("Ctrl+Enter", "Finish typing an annotation")];
        panel.Children.Add(Group("While capturing", shortcuts.Select(s => Row(s.Description, new TextBlock { Text = s.Shortcut, FontFamily = new FontFamily("Consolas"), Foreground = Brushes.DimGray })).ToArray()));
        return panel;
    }
    private TextBox Shortcut(Func<HotKey> get, Action<HotKey> set)
    {
        var field = new TextBox { Text = get().ToString(), IsReadOnly = true, Width = 160, Padding = new Thickness(6), HorizontalContentAlignment = HorizontalAlignment.Center };
        field.PreviewMouseLeftButtonDown += (_, e) => { field.Focus(); field.SelectAll(); e.Handled = true; };
        field.PreviewKeyDown += (_, e) =>
        {
            var key = e.Key == Key.System ? e.SystemKey : e.Key;
            var hotKey = HotKey.FromKey(key, Keyboard.Modifiers);
            e.Handled = true;
            if (hotKey == null) return;
            if (!hotKey.IsEmpty && new[] { settings.CaptureAreaHotKey, settings.SaveFullScreenHotKey, settings.CopyFullScreenHotKey }.Any(existing => existing == hotKey && existing != get()))
            {
                field.ToolTip = "This shortcut is already assigned to another capture action."; return;
            }
            set(hotKey); field.Text = hotKey.ToString(); field.ToolTip = null;
        };
        return field;
    }
    private UIElement Output()
    {
        var panel = Column();
        var directory = new TextBlock { Text = settings.SaveDirectory, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 225, Foreground = Brushes.DimGray, VerticalAlignment = VerticalAlignment.Center };
        var choose = new Button { Content = "Choose…", Padding = new Thickness(8, 4, 8, 4), Margin = new Thickness(8, 0, 0, 0) };
        choose.Click += (_, _) => { var dialog = new OpenFolderDialog { Title = "Choose screenshots folder", InitialDirectory = settings.SaveDirectory }; if (dialog.ShowDialog(this) == true) { settings.SaveDirectory = dialog.FolderName; directory.Text = dialog.FolderName; } };
        var pathRow = new StackPanel { Orientation = Orientation.Horizontal }; pathRow.Children.Add(directory); pathRow.Children.Add(choose);
        var name = new TextBox { Text = settings.FilenameTemplate, Width = 255, Padding = new Thickness(4) }; name.TextChanged += (_, _) => settings.FilenameTemplate = name.Text;
        panel.Children.Add(Group("Files", Row("Save to", pathRow), Row("File name", name), Help("Tokens: {date} {time} {timestamp} {width} {height}")));
        var quality = Row("Quality", Slider(settings.JpegQuality, 0.3, 1, v => settings.JpegQuality = v, "30%", "100%"));
        quality.Visibility = settings.ImageFormat == ImageFormat.Jpeg ? Visibility.Visible : Visibility.Collapsed;
        panel.Children.Add(Group(null, Row("Format", Combo(Enum.GetValues<ImageFormat>(), settings.ImageFormat, v => { settings.ImageFormat = v; quality.Visibility = v == ImageFormat.Jpeg ? Visibility.Visible : Visibility.Collapsed; }, v => v switch { ImageFormat.Png => "PNG", ImageFormat.Jpeg => "JPEG", _ => "TIFF" })), quality, Check("Also copy to the clipboard when saving", settings.CopyAfterSave, v => settings.CopyAfterSave = v)));
        return panel;
    }
    private UIElement Capture()
    {
        var panel = Column();
        panel.Children.Add(Group("Overlay", Check("Show the pixel magnifier", settings.ShowMagnifier, v => settings.ShowMagnifier = v), Check("Show selection dimensions", settings.ShowDimensions, v => settings.ShowDimensions = v), Row("Dim the rest of the screen", Slider(settings.DimOpacity, 0, 0.85, v => settings.DimOpacity = v, "Off", "Dark"))));
        panel.Children.Add(Group("Capture", Check("Capture at full display resolution", settings.NativeResolution, v => settings.NativeResolution = v), Check("Include the mouse pointer", settings.CaptureCursor, v => settings.CaptureCursor = v)));
        panel.Children.Add(Group("Annotations", Check("Remember the last tool used", settings.RememberLastTool, v => settings.RememberLastTool = v), Row("Line thickness", Slider(settings.LineWidth, 1, 12, v => settings.LineWidth = v, "1", "12", 1)), Row("Text size", Slider(settings.FontSize, 10, 48, v => settings.FontSize = v, "10", "48", 1))));
        return panel;
    }
    private static TabItem Tab(string title, UIElement content) => new() { Header = title, Content = new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled } };
    private static StackPanel Column() => new() { Margin = new Thickness(16, 18, 16, 12) };
    private static Border Group(string? title, params UIElement[] rows)
    {
        var column = new StackPanel();
        if (title != null) column.Children.Add(new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 8), Foreground = Brushes.DimGray });
        foreach (var row in rows) column.Children.Add(row);
        return new Border { Background = Brushes.White, CornerRadius = new CornerRadius(9), Padding = new Thickness(14), Margin = new Thickness(0, 0, 0, 14), Child = column };
    }
    private static Grid Row(string label, UIElement control)
    {
        var grid = new Grid { Margin = new Thickness(0, 5, 0, 5) }; grid.ColumnDefinitions.Add(new ColumnDefinition()); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) }); Grid.SetColumn(control, 1); grid.Children.Add(control); AutomationProperties.SetName(control, label); return grid;
    }
    private static TextBlock Help(string text) => new() { Text = text, FontSize = 11, Foreground = Brushes.Gray, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) };
    private static CheckBox Check(string label, bool value, Action<bool> changed)
    {
        var check = new CheckBox { Content = label, IsChecked = value, Margin = new Thickness(0, 6, 0, 6) }; check.Checked += (_, _) => changed(true); check.Unchecked += (_, _) => changed(false); return check;
    }
    private static ComboBox Combo<T>(IEnumerable<T> values, T current, Action<T> changed, Func<T, string> display) where T : struct
    {
        var combo = new ComboBox { MinWidth = 150, MaxWidth = 255, Padding = new Thickness(4, 2, 4, 2) };
        foreach (var value in values) combo.Items.Add(new ComboBoxItem { Content = display(value), Tag = value });
        combo.SelectedItem = combo.Items.Cast<ComboBoxItem>().First(v => Equals(v.Tag, current));
        combo.SelectionChanged += (_, _) => { if (combo.SelectedItem is ComboBoxItem { Tag: T value }) changed(value); }; return combo;
    }
    private static UIElement Slider(double value, double min, double max, Action<double> changed, string low, string high, double step = 0)
    {
        var grid = new Grid { Width = 210 }; grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); grid.ColumnDefinitions.Add(new ColumnDefinition()); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(new TextBlock { Text = low, FontSize = 11, Foreground = Brushes.Gray, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 5, 0) });
        var slider = new System.Windows.Controls.Slider { Minimum = min, Maximum = max, Value = value, TickFrequency = step == 0 ? 1 : step, IsSnapToTickEnabled = step != 0, IsMoveToPointEnabled = true, VerticalAlignment = VerticalAlignment.Center };
        slider.ValueChanged += (_, _) => changed(slider.Value); Grid.SetColumn(slider, 1); grid.Children.Add(slider);
        var maximum = new TextBlock { Text = high, FontSize = 11, Foreground = Brushes.Gray, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(5, 0, 0, 0) }; Grid.SetColumn(maximum, 2); grid.Children.Add(maximum); return grid;
    }
}
