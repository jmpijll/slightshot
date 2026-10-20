using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;
using Slightshot.Core;

namespace Slightshot;

// Fixture settings files are written by this test; the Run value is restored afterwards.
internal static class SettingsRecoverySmokeTest
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public static void Run(string directory, List<string> checks)
    {
        string fixtures = Path.Combine(directory, "settings-fixtures");
        if (Directory.Exists(fixtures)) Directory.Delete(fixtures, true);
        var report = new List<string>();

        string corrupt = Fixture(fixtures, "corrupt", """{"ImageFormat": 1, "PlaySound": fal""");
        byte[] original = File.ReadAllBytes(corrupt);
        var reset = Settings.Load(corrupt, out string? notice);
        string[] backups = Directory.GetFiles(Path.GetDirectoryName(corrupt)!, "settings.corrupt-*.json");
        Require(backups.Length == 1 && File.ReadAllBytes(backups[0]).SequenceEqual(original), "truncated JSON is copied to settings.corrupt-<timestamp>.json");
        Require(notice != null && notice.Contains(Path.GetFileName(backups[0]), StringComparison.Ordinal), "the notice names the backup");
        reset.Save();
        Settings.Load(corrupt, out string? second);
        Require(second == null && reset.ImageFormat == ImageFormat.Png, "defaults are saved after the backup and the notice is shown once");
        report.Add($"Truncated JSON → defaults; backup {Path.GetFileName(backups[0])}");
        report.Add($"  Notice: {notice}");

        string fields = Fixture(fixtures, "fields", """
            {"CaptureAreaHotKey": null, "SaveFullScreenHotKey": {"Key": 56, "Modifiers": 0}, "ImageFormat": 9, "DefaultAction": 5,
             "RecordingQuality": 9, "LineWidth": 40, "JpegQuality": 0.01, "PlaySound": false, "AnnotationColor": "#123456"}
            """);
        var partial = Settings.Load(fields, out string? fieldNotice);
        var defaults = new Settings();
        Require(partial.CaptureAreaHotKey == defaults.CaptureAreaHotKey && partial.SaveFullScreenHotKey == defaults.SaveFullScreenHotKey, "null and invalid hotkeys fall back to defaults");
        Require(partial.ImageFormat == ImageFormat.Png && partial.DefaultAction == DefaultAction.Copy && partial.RecordingQuality == RecordingQuality.Balanced, "undefined enum values fall back");
        Require(partial.LineWidth == 12 && partial.JpegQuality == 0.3 && partial.AnnotationColor == "#FF3B30" && !partial.PlaySound, "ranges clamp and valid fields are kept");
        Require(fieldNotice != null && Directory.GetFiles(Path.GetDirectoryName(fields)!, "settings.corrupt-*.json").Length == 1, "field resets keep a backup and notify");
        using (var hotKeys = new HotKeyService(_ => { })) hotKeys.Register(partial);
        report.Add("Null/invalid hotkeys, enums 9/5/9 → defaults; LineWidth 40 → 12, JpegQuality 0.01 → 0.3; PlaySound false kept");
        report.Add($"  Notice: {fieldNotice}");
        report.Add("  Production HotKeyService.Register(settings) ran without an exception");
        checks.Add("Settings recovery: truncated JSON backed up before defaults are saved, one notice; null/invalid hotkeys and undefined enums fall back, ranges clamp, HotKeyService registers the result");

        string executable = Environment.ProcessPath!;
        using var run = Registry.CurrentUser.CreateSubKey(RunKey);
        object? previous = run.GetValue("Slightshot");
        try
        {
            const string moved = @"C:\Users\Example\Downloads\Slightshot.exe";
            run.SetValue("Slightshot", LaunchAtLogin.Command(moved));
            var other = new SettingsWindow(new Settings { PlaySound = false }, false);
            var check = LoginCheck(other);
            Require(check.IsChecked == false, "a Run entry for another copy shows launch at login as off");
            SaveVisual((FrameworkElement)other.Content, 540, 360, Path.Combine(directory, "settings-login-other-copy.png"));
            check.IsChecked = true;
            Require(run.GetValue("Slightshot") as string == LaunchAtLogin.Command(executable), "turning launch at login on rewrites the Run entry to this executable");
            var current = new SettingsWindow(new Settings { PlaySound = false }, false);
            Require(LoginCheck(current).IsChecked == true, "a Run entry for this executable shows launch at login as on");
            SaveVisual((FrameworkElement)current.Content, 540, 360, Path.Combine(directory, "settings-login-this-copy.png"));
            report.Add($"Run = \"{moved}\" → toggle off; toggled on → Run = {LaunchAtLogin.Command(executable)} → toggle on");
            checks.Add("Launch at login: another copy's Run entry shows off; enabling rewrites it to this executable and shows on");
        }
        finally
        {
            if (previous != null) run.SetValue("Slightshot", previous); else run.DeleteValue("Slightshot", false);
        }
        SaveReport(report, Path.Combine(directory, "settings-recovery-report.png"));
    }

    private static string Fixture(string root, string name, string json)
    {
        string folder = Path.Combine(root, name); Directory.CreateDirectory(folder);
        string path = Path.Combine(folder, "settings.json"); File.WriteAllText(path, json); return path;
    }
    private static CheckBox LoginCheck(SettingsWindow window)
    {
        var content = (FrameworkElement)window.Content;
        content.Measure(new Size(540, 580)); content.Arrange(new Rect(0, 0, 540, 580)); content.UpdateLayout();
        return Descendants(content).OfType<CheckBox>().Single(box => Equals(box.Content, "Launch Slightshot at login"));
    }
    private static void SaveReport(List<string> lines, string path)
    {
        var panel = new StackPanel { Background = Brushes.White, Margin = new Thickness(0) };
        panel.Children.Add(new TextBlock { Text = "Windows settings recovery · automated native fixture", FontWeight = FontWeights.SemiBold, Margin = new Thickness(12, 12, 12, 8) });
        foreach (string line in lines) panel.Children.Add(new TextBlock { Text = line, FontFamily = new FontFamily("Consolas"), FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(12, 2, 12, 2) });
        panel.Measure(new Size(900, double.PositiveInfinity));
        SaveVisual(panel, 900, (int)Math.Ceiling(panel.DesiredSize.Height) + 12, path);
    }
    private static void SaveVisual(FrameworkElement element, int width, int height, string path)
    {
        element.Measure(new Size(width, height)); element.Arrange(new Rect(0, 0, width, height)); element.UpdateLayout();
        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32); bitmap.Render(element);
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = File.Create(path); encoder.Save(stream);
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
    {
        for (int index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
        {
            var child = VisualTreeHelper.GetChild(parent, index);
            yield return child;
            foreach (var descendant in Descendants(child)) yield return descendant;
        }
    }
    private static void Require(bool condition, string check) { if (!condition) throw new InvalidOperationException($"Settings recovery smoke test failed: {check}"); }
}
