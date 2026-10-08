using System.IO;
using System.Diagnostics;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Slightshot.Core;

namespace Slightshot;

// Native WPF rendering/export checks run on Windows CI; no real user screenshot is captured.
internal static class SmokeTest
{
    public static void Run(string directory)
    {
        Directory.CreateDirectory(directory);
        var checks = new List<string>();
        IconSmokeTest.Run(directory, checks);
        RasterEffectSmokeTest.Run(directory, checks);
        StepSmokeTest.Run(directory, checks);
        ScreenshotRetrySmokeTest.Run(directory, checks);
        foreach (double scale in new[] { 1.0, 1.25, 1.5, 2.0 })
        {
            var display = Fixture(scale);
            RectD selection = new(100, 100, 560, 300);
            Annotation[] annotations = [
                new(Tool.Pen, [new(250, 180), new(290, 180), new(320, 180)], "#FF3B30", 3),
                new(Tool.Line, [new(150, 230), new(320, 250)], "#0A84FF", 3),
                new(Tool.Arrow, [new(400, 270), new(570, 160)], "#FF3B30", 3),
                new(Tool.Rectangle, [new(130, 130), new(350, 290)], "#34C759", 3),
                new(Tool.Marker, [new(180, 335), new(320, 335), new(500, 335)], "#FFCC00", 3),
                new(Tool.Text, [new(390, 300)], "#FFFFFF", 3, 18, "Slightshot"),
                new(Tool.Step, [new(150, 175)], "#FF3B30", 3, StepNumber: 1),
                new(Tool.Step, [new(360, 230)], "#FFCC00", 3, StepNumber: 12)
            ];
            var output = AnnotationRenderer.Flatten(display, selection, annotations, true);
            Require(output.PixelWidth == (int)(560 * scale) && output.PixelHeight == (int)(300 * scale), $"native export size @{scale}");
            var red = Pixel(output, (int)(190 * scale), (int)(80 * scale));
            Require(red.R > 220 && red.G < 100 && red.B < 100, $"pen pixel @{scale}");
            var logical = AnnotationRenderer.Flatten(display, selection, annotations, false);
            Require(logical.PixelWidth == 560 && logical.PixelHeight == 300, $"logical export size @{scale}");
            foreach (var format in Enum.GetValues<ImageFormat>())
            {
                using var stream = new MemoryStream(); OutputService.Encode(output, format, 0.9).Save(stream); stream.Position = 0;
                var decoded = BitmapDecoder.Create(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad).Frames[0];
                Require(decoded.PixelWidth == output.PixelWidth && decoded.PixelHeight == output.PixelHeight, $"{format} encoder roundtrip @{scale}");
                File.WriteAllBytes(Path.Combine(directory, $"annotations-{scale:0.##}x.{format.Extension()}"), stream.ToArray());
            }
            checks.Add($"{scale:0.##}×: native and logical export dimensions, red annotation pixels, PNG/JPEG/TIFF decode passed");
            if (scale != 1) continue;
            var window = new OverlayWindow(display, new Settings { PlaySound = false }, true, _ => { }, () => { }, (_, _, _) => { });
            window.PrepareSmokeFixture(selection, annotations);
            var root = (FrameworkElement)window.Content;
            SaveVisual(root, 800, 520, Path.Combine(directory, "overlay-parity.png"));
            // A full-display selection exercises toolbar edge flipping/tucking.
            var edge = new OverlayWindow(display, new Settings { PlaySound = false }, true, _ => { }, () => { }, (_, _, _) => { });
            edge.PrepareSmokeFixture(new RectD(0, 0, 800, 520), []);
            SaveVisual((FrameworkElement)edge.Content, 800, 520, Path.Combine(directory, "overlay-edge-parity.png"));
            var hint = new OverlayWindow(display, new Settings { PlaySound = false }, true, _ => { }, () => { }, (_, _, _) => { });
            SaveVisual((FrameworkElement)hint.Content, 800, 520, Path.Combine(directory, "overlay-hint-parity.png"));
            foreach (bool dark in new[] { false, true })
            {
                var prefs = new SettingsWindow(new Settings { PlaySound = false }, dark);
                SaveVisual((FrameworkElement)prefs.Content, 540, 580, Path.Combine(directory, $"settings-{(dark ? "dark" : "light")}-parity.png"));
                var expectedVersion = FileVersionInfo.GetVersionInfo(Environment.ProcessPath!).ProductVersion!.Split('+')[0];
                var version = Descendants((DependencyObject)prefs.Content).OfType<TextBlock>()
                    .Single(block => AutomationProperties.GetName(block) == "Version");
                Require(version.Text == $"{expectedVersion} · Windows", "Settings version matches the running executable");
                Require(AppInfo.AboutText.StartsWith($"Slightshot {expectedVersion} for Windows\n", StringComparison.Ordinal), "About version matches the running executable");
            }
        }
        File.WriteAllText(Path.Combine(directory, "validation.json"), JsonSerializer.Serialize(new { platform = "Windows WPF", source = "Synthetic fixture; not a live screen capture or manual interaction recording", checks }, new JsonSerializerOptions { WriteIndented = true }));
    }
    private static CapturedDisplay Fixture(double scale)
    {
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            dc.DrawRectangle(AnnotationRenderer.Brush("#EAF0F5"), null, new Rect(0, 0, 800, 520));
            dc.DrawRoundedRectangle(AnnotationRenderer.Brush("#FFFFFF"), null, new Rect(70, 70, 660, 380), 12, 12);
            dc.DrawRoundedRectangle(AnnotationRenderer.Brush("#313947"), null, new Rect(70, 70, 660, 38), 12, 12);
            dc.DrawText(AnnotationRenderer.Text("Slightshot · Windows parity fixture", 14, Brushes.White), new Point(90, 80));
            for (int i = 0; i < 5; i++)
            {
                dc.DrawRoundedRectangle(AnnotationRenderer.Brush(i == 0 ? "#EDF4FD" : "#F5F6F8"), null, new Rect(110, 130 + i * 54, 580, 40), 6, 6);
                dc.DrawText(AnnotationRenderer.Text(i == 0 ? "Capture, annotate, copy or save." : "Frozen screenshot content", 13, AnnotationRenderer.Brush("#455065")), new Point(140, 142 + i * 54));
            }
        }
        int width = (int)(800 * scale), height = (int)(520 * scale);
        var image = new RenderTargetBitmap(width, height, 96 * scale, 96 * scale, PixelFormats.Pbgra32); image.Render(visual); image.Freeze();
        return new(image, 0, 0, width, height, scale);
    }
    private static Color Pixel(BitmapSource image, int x, int y)
    {
        var converted = new FormatConvertedBitmap(image, PixelFormats.Bgra32, null, 0); byte[] pixel = new byte[4]; converted.CopyPixels(new Int32Rect(x, y, 1, 1), pixel, 4, 0); return Color.FromArgb(pixel[3], pixel[2], pixel[1], pixel[0]);
    }
    private static void SaveVisual(FrameworkElement element, int width, int height, string path)
    {
        element.Measure(new Size(width, height)); element.Arrange(new Rect(0, 0, width, height)); element.UpdateLayout();
        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32); bitmap.Render(element);
        using var stream = File.Create(path); OutputService.Encode(bitmap, ImageFormat.Png, 1).Save(stream);
    }
    private static void Require(bool condition, string check) { if (!condition) throw new InvalidOperationException($"Windows smoke test failed: {check}"); }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
    {
        for (int index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
        {
            var child = VisualTreeHelper.GetChild(parent, index);
            yield return child;
            foreach (var descendant in Descendants(child)) yield return descendant;
        }
    }
}
