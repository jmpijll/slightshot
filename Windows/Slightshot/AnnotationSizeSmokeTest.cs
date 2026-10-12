using System.IO;
using System.Reflection;
using System.Text.Json;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Slightshot.Core;

namespace Slightshot;

// Native WPF editors, synthetic source, automated production scroll-handler calls.
internal static class AnnotationSizeSmokeTest
{
    internal static async Task RunAsync(string directory, List<string> checks)
    {
        var source = Fixture();
        CheckHaloRendering();
        foreach (bool clipboard in new[] { false, true })
        {
            var settings = new Settings { LineWidth = 3, FontSize = 18, PlaySound = false };
            var window = clipboard
                ? new OverlayWindow(source, settings, _ => { }, () => { }, (_, _, _) => { })
                : new OverlayWindow(new CapturedDisplay(source.Image, 0, 0, 800, 600, 1), settings, false, _ => { }, () => { }, (_, _, _) => { });
            window.PrepareSmokeFixture(new(60, 60, 680, 500), []);
            var root = (FrameworkElement)window.Content;
            if (clipboard)
            {
                // ScrollViewer needs a presentation source for its viewport and
                // the editor's point-to-window transform before native rendering.
                window.Show();
                await Task.Delay(100);
                window.UpdateLayout();
            }
            Layout(root, 800, 600);
            var surface = Field<OverlaySurface>(window, "surface");
            var toolbar = Field<Toolbar>(window, "toolbar");
            string prefix = clipboard ? "scroll-clipboard" : "scroll-capture";
            AddArrow(window, surface, 120);
            Save(root, directory, prefix + "-before");
            Require(window.ChangeSizeAt(new(580, 270), 720) && settings.LineWidth == 9, "up increases to 9");
            AddArrow(window, surface, 270);
            window.ChangeSizeAt(new(580, 270), 120); window.ChangeSizeAt(new(580, 270), -120);
            CheckHaloPosition(window, surface, root, new(580, 270), new(false, 9));
            Save(root, directory, prefix + "-increased");
            Require(window.ChangeSizeAt(new(580, 420), -840) && settings.LineWidth == 2, "down decreases to 2");
            AddArrow(window, surface, 420);
            window.ChangeSizeAt(new(580, 420), 120); window.ChangeSizeAt(new(580, 420), -120);
            Save(root, directory, prefix + "-decreased");
            Require(surface.Annotations.Select(a => a.Width).SequenceEqual(new[] { 3.0, 9.0, 2.0 }), "old marks keep their widths");
            surface.Annotations.Undo(); window.ChangeSizeAt(new(580, 420), 120); surface.Annotations.Redo();
            Require(surface.Annotations.Last().Width == 2, "scroll preserves redo and original style");
            toolbar.Select(Tool.Text); window.ChangeSizeAt(new(580, 490), 480);
            Require(settings.FontSize == 26, "text wheel changes font size");
            Invoke(window, "BeginText", new PointD(180, 490));
            Field<TextBox>(window, "textEntry").Text = "Scroll-sized text";
            Require(!window.ChangeSizeAt(new(580, 490), 120) && settings.FontSize == 26, "typing keeps native scroll behavior");
            Invoke(window, "CommitText");
            window.ChangeSizeAt(new(580, 490), 120); window.ChangeSizeAt(new(580, 490), -120);
            Require(surface.Annotations.Last().FontSize == 26, "new text takes wheel size");
            Save(root, directory, prefix + "-text");
            toolbar.Select(Tool.Arrow);
            Require(!window.ChangeSizeAt(new(10, 10), 120), "outside selection keeps pan scrolling");
            foreach (var tool in new[] { Tool.Blur, Tool.Pixelate, Tool.Step })
            { toolbar.Select(tool); Require(!window.ChangeSizeAt(new(580, 490), 120), "fixed-size tool does not consume wheel"); }
            toolbar.Select(Tool.Arrow);
            Invoke(toolbar, "TogglePalette");
            window.ChangeSizeAt(new(580, 490), 120);
            var slider = Descendants(root).OfType<Slider>().Single(s => AutomationProperties.GetName(s) == "Thickness");
            Require(slider.Value == settings.LineWidth, "palette slider synchronizes with wheel");
            Require(Descendants(root).OfType<AnnotationSizeIndicator>().Any(i => i.Visibility == Visibility.Visible), "native size indicator shown");
            window.Close();
            checks.Add($"{prefix}: up/down, new text, fixed tools, outside selection, draft text, original widths, redo, palette synchronization and pointer-centered halo passed");
        }

        var videoSettings = new Settings { LineWidth = 3, FontSize = 18 };
        var history = new VideoAnnotationHistory(TimeSpan.FromSeconds(5));
        var canvas = new VideoAnnotationSurface(history, videoSettings, 800, 600) { ActiveTool = Tool.Arrow, ViewScale = 0.5 };
        canvas.SetFrame(source.Image);
        var chrome = new Canvas(); var indicator = new AnnotationSizeIndicator();
        var grid = new Grid(); grid.Children.Add(new Viewbox { Child = canvas }); grid.Children.Add(chrome);
        Layout(grid, 800, 600);
        canvas.SizeChangedByWheel = (change, point) => indicator.Show(change, canvas.TranslatePoint(point, chrome), chrome);
        Require(canvas.ChangeSizeAt(new(580, 270), 720) && videoSettings.LineWidth == 9, "video canvas wheel adjusts width");
        typeof(VideoAnnotationSurface).GetField("anchor", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(canvas, new PointD(180, 270));
        typeof(VideoAnnotationSurface).GetField("gestureScale", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(canvas, 0.5);
        var mark = (Annotation)Invoke(canvas, "Make", new PointD(560, 270))!;
        Require(mark.Width == 18, "video source width respects zoom");
        history.Add(mark); canvas.Refresh();
        Save(grid, directory, "scroll-video");
        canvas.ActiveTool = Tool.Text; canvas.ChangeSizeAt(new(580, 490), 480);
        Require(videoSettings.FontSize == 26, "video font size changes");
        checks.Add("scroll-video: production wheel handler, zoom-correct annotation size, text sizing and native indicator passed");
        File.WriteAllText(Path.Combine(directory, "scroll-validation.json"), JsonSerializer.Serialize(new
        {
            platform = "Windows WPF", sourceCommit = Environment.GetEnvironmentVariable("SLIGHTSHOT_SOURCE_COMMIT"),
            source = "Synthetic 800×600 image. Automated production scroll-handler calls and annotation factory. Native WPF control renders; no manual desktop interaction.",
            checks = checks.Where(c => c.StartsWith("scroll-"))
        }, new JsonSerializerOptions { WriteIndented = true }));
    }

    private static void CheckHaloPosition(OverlayWindow window, OverlaySurface surface, FrameworkElement root, Point point, AnnotationSizeChange change)
    {
        var halo = Descendants(root).OfType<AnnotationSizeIndicator>().Single();
        var host = Field<Canvas>(window, "toolbarChrome");
        var expected = surface.TranslatePoint(point, host);
        Require(Math.Abs(halo.Width - change.IndicatorDiameter) < 0.001 && halo.Width == halo.Height, "halo scales with current thickness");
        Require(Math.Abs(Canvas.GetLeft(halo) + halo.Width / 2 - expected.X) < 0.001 &&
            Math.Abs(Canvas.GetTop(halo) + halo.Height / 2 - expected.Y) < 0.001, "halo is centered on the injected pointer");
        halo.Move(new(expected.X + 20, expected.Y + 10), host);
        Require(Math.Abs(Canvas.GetLeft(halo) + halo.Width / 2 - expected.X - 20) < 0.001, "visible halo follows pointer movement");
        halo.Move(expected, host);
    }

    private static void CheckHaloRendering()
    {
        var host = new Canvas(); var halo = new AnnotationSizeIndicator();
        halo.Show(new(false, 12), new(35, 35), host);
        Layout(host, 70, 70);
        var bitmap = new RenderTargetBitmap(70, 70, 96, 96, PixelFormats.Pbgra32); bitmap.Render(host);
        var pixels = new byte[70 * 70 * 4]; bitmap.CopyPixels(pixels, 70 * 4, 0);
        byte Alpha(int x, int y) => pixels[(y * 70 + x) * 4 + 3];
        Require(Alpha(8, 8) == 0, "halo has transparent corners, not a text panel");
        Require(Alpha(35, 35) is > 20 and < 70, "halo fill remains translucent over the source");
        Require(Alpha(35, 9) > 80, "halo has a visible ring");
        Require(!halo.IsHitTestVisible && VisualTreeHelper.GetChildrenCount(halo) == 0, "halo never intercepts input and contains no visible text");
        Require(FrameworkElementAutomationPeer.CreatePeerForElement(halo).GetName() == "Thickness 12 pt", "halo retains its accessible size");
        halo.Show(new(false, 1), new(2, 3), host);
        Require(Canvas.GetLeft(halo) + halo.Width / 2 == 2 && Canvas.GetTop(halo) + halo.Height / 2 == 3,
            "halo stays centered at viewport edges rather than jumping away from the pointer");
        halo.Hide();
    }

    private static void AddArrow(OverlayWindow window, OverlaySurface surface, double y)
    {
        typeof(OverlayWindow).GetField("anchor", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(window, new PointD(180, y));
        surface.Annotations.Add((Annotation)Invoke(window, "MakeAnnotation", new PointD(560, y))!);
        surface.InvalidateVisual();
    }
    private static EditorImageSource Fixture()
    {
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            dc.DrawRectangle(AnnotationRenderer.Brush("#F0F2F7"), null, new Rect(0, 0, 800, 600));
            foreach (var (text, y) in new[] { ("Scroll to resize annotations", 25), ("Before · 3 pt", 90), ("Scroll up · 9 pt", 240), ("Scroll down · 2 pt", 390), ("Text · 26 pt", 475) })
                dc.DrawText(AnnotationRenderer.Text(text, y == 25 ? 24 : 16, Brushes.DimGray), new Point(80, y));
        }
        var bitmap = new RenderTargetBitmap(800, 600, 96, 96, PixelFormats.Pbgra32); bitmap.Render(visual); bitmap.Freeze();
        return new EditorImageSource(bitmap, 1);
    }
    private static void Layout(FrameworkElement root, double width, double height)
    { root.Measure(new Size(width, height)); root.Arrange(new Rect(0, 0, width, height)); root.UpdateLayout(); }
    private static void Save(FrameworkElement root, string directory, string name)
    {
        root.UpdateLayout();
        var bitmap = new RenderTargetBitmap((int)root.ActualWidth, (int)root.ActualHeight, 96, 96, PixelFormats.Pbgra32); bitmap.Render(root);
        var pixels = new byte[bitmap.PixelWidth * bitmap.PixelHeight * 4]; bitmap.CopyPixels(pixels, bitmap.PixelWidth * 4, 0);
        int redPixels = 0;
        for (int offset = 0; offset < pixels.Length; offset += 4)
            if (pixels[offset + 2] > 180 && pixels[offset + 1] < 120 && pixels[offset] < 120) redPixels++;
        Require(redPixels > 1400, "native evidence includes the source annotations, not only toolbar chrome");
        using var stream = File.Create(Path.Combine(directory, name + ".png")); OutputService.Encode(bitmap, ImageFormat.Png, 1).Save(stream);
    }
    private static T Field<T>(object target, string name) => (T)target.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(target)!;
    private static object? Invoke(object target, string name, params object[] args) => target.GetType().GetMethod(name, BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(target, args);
    private static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
        {
            var child = VisualTreeHelper.GetChild(parent, i); yield return child;
            foreach (var item in Descendants(child)) yield return item;
        }
    }
    private static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException("Scroll smoke test: " + message); }
}
