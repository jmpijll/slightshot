using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Slightshot.Core;

namespace Slightshot;

// Exercises the editor's real history commands and saves native WPF evidence.
internal static class RedoSmokeTest
{
    private const string UndoTooltip = "Undo  Ctrl+Z";
    private const string RedoTooltip = "Redo  Ctrl+Y / Ctrl+Shift+Z";

    internal static void Run(string directory, List<string> checks)
    {
        foreach (double scale in new[] { 1.0, 1.25, 1.5, 2.0 })
        {
            var display = Fixture(scale);
            RectD selection = new(100, 100, 560, 300);
            Annotation[] original = [
                new(Tool.Pen, [new(180, 170), new(240, 170), new(300, 170)], "#FF3B30", 18),
                new(Tool.Step, [new(340, 190)], "#0A84FF", 3, StepNumber: 1),
                new(Tool.Blur, [new(150, 145), new(280, 200)], "#FF3B30", 3),
                new(Tool.Text, [new(160, 250)], "#00C7BE", 3, 22, "Redo restores the original marks"),
                new(Tool.Pixelate, [new(315, 160), new(370, 220)], "#FF3B30", 3),
                new(Tool.Step, [new(500, 260)], "#FFCC00", 3, StepNumber: 2)
            ];
            BitmapSource? exported = null;
            var window = new OverlayWindow(display, new Settings { PlaySound = false }, false, _ => { }, () => { }, (_, _, image) => exported = image);
            window.PrepareSmokeFixture(selection, original);
            var surface = Surface(window);
            var before = Export(window, () => exported);
            Require(!Button(window, RedoTooltip).IsEnabled, "redo is unavailable before undo");
            Save(before, Path.Combine(directory, $"redo-export-before-{scale:0.##}x.png"));
            Save(Render(window, display), Path.Combine(directory, $"redo-overlay-before-{scale:0.##}x.png"));

            Click(window, UndoTooltip);
            Require(Annotation.NextStepNumber(surface.Annotations) == 2 && Button(window, RedoTooltip).IsEnabled, "undo enables redo and restores the next step number");
            Require(Shortcut(window, Key.Z, ModifierKeys.Control), "Ctrl+Z handles committed history");
            var undone = Export(window, () => exported);
            Require(!Bytes(before).SequenceEqual(Bytes(undone)), "undo removes the later effect and numbered step from export");
            Require(Bytes(undone).SequenceEqual(Bytes(AnnotationRenderer.Flatten(display, selection, original.Take(4), true))), "undo retains all earlier marks in original order");
            Save(undone, Path.Combine(directory, $"redo-export-undone-{scale:0.##}x.png"));
            Save(Render(window, display), Path.Combine(directory, $"redo-overlay-undone-{scale:0.##}x.png"));

            Click(window, RedoTooltip);
            Require(ReferenceEquals(surface.Annotations[^1], original[4]), "toolbar redo restores the original raster effect");
            Require(Shortcut(window, Key.Y, ModifierKeys.Control), "Ctrl+Y handles committed redo");
            var restored = Export(window, () => exported);
            Require(Bytes(before).SequenceEqual(Bytes(restored)), "redo restores exact exported pixels including raster ordering");
            Require(surface.Annotations.SequenceEqual(original) && Annotation.NextStepNumber(surface.Annotations) == 3, "redo restores original annotations and advances step numbering");
            Require(!Button(window, RedoTooltip).IsEnabled, "redo becomes unavailable when exhausted");
            Save(restored, Path.Combine(directory, $"redo-export-restored-{scale:0.##}x.png"));
            Save(Render(window, display), Path.Combine(directory, $"redo-overlay-restored-{scale:0.##}x.png"));
            CheckPreview(window, display, selection, restored);

            for (int cycle = 0; cycle < 2; cycle++)
            {
                for (int i = 0; i < original.Length; i++) Click(window, UndoTooltip);
                Require(!surface.Annotations.CanUndo && Annotation.NextStepNumber(surface.Annotations) == 1, "undoing every mark resets history and steps");
                for (int i = 0; i < original.Length; i++) Require(Shortcut(window, Key.Z, ModifierKeys.Control | ModifierKeys.Shift), "Ctrl+Shift+Z replays committed history");
                Require(Bytes(before).SequenceEqual(Bytes(Export(window, () => exported))), "repeated cycles restore all original pixels");
            }
            Click(window, UndoTooltip);
            Invoke(window, "BeginText", new PointD(180, 320));
            var entry = Descendants((DependencyObject)window.Content).OfType<TextBox>().Single();
            Require(!Button(window, RedoTooltip).IsEnabled, "annotation redo is disabled while typing");
            // SelectedText uses WPF's native selection change block, creating
            // undo history even in a rendered window without desktop focus.
            entry.SelectedText = "Draft text";
            Require(entry.CanUndo, "draft has native text undo history");
            Require(!Shortcut(window, Key.Z, ModifierKeys.Control), "draft Ctrl+Z remains available to the native TextBox");
            entry.Undo();
            Require(entry.Text.Length == 0 && entry.CanRedo, "native text undo changes only the draft");
            Require(Shortcut(window, Key.Y, ModifierKeys.Control) && entry.Text == "Draft text", "draft Ctrl+Y restores native text history");
            entry.Undo();
            Require(Shortcut(window, Key.Z, ModifierKeys.Control | ModifierKeys.Shift) && entry.Text == "Draft text", "draft Ctrl+Shift+Z restores native text history");
            Require(surface.Annotations.Count == 5 && surface.Annotations.CanRedo, "draft undo and redo leave committed history untouched");
            Invoke(window, "Undo");
            Require(surface.Annotations.Count == 5 && Button(window, RedoTooltip).IsEnabled, "discarding a draft retains committed redo");
            Invoke(window, "BeginText", new PointD(180, 320));
            entry = Descendants((DependencyObject)window.Content).OfType<TextBox>().Single();
            entry.Text = "A new committed annotation";
            Invoke(window, "CommitText");
            Require(!surface.Annotations.CanRedo && !Button(window, RedoTooltip).IsEnabled, "committing new text invalidates the old redo branch");
            Require(Annotation.NextStepNumber(surface.Annotations) == 2, "new text does not consume the undone step number");
            Click(window, UndoTooltip);
            Invoke(window, "SelectDisplay");
            Require(surface.Annotations.Count == 5 && !surface.Annotations.CanRedo, "full-display selection retains marks and invalidates redo");
            Click(window, UndoTooltip);
            Invoke(window, "StartSelection", new PointD(700, 460));
            Require(surface.Annotations.Count == 0 && !surface.Annotations.CanRedo && !surface.Annotations.CanUndo, "starting a new selection clears undo and redo");
            Require(Annotation.NextStepNumber(surface.Annotations) == 1, "a fresh selection starts at step one");
            checks.Add($"{scale:0.##}× redo: native toolbar, Ctrl+Z/Y/Shift+Z handler, original text/vector/effect/step objects and pixels, repeated cycles, native draft text editing, new-edit and selection invalidation passed");
        }
    }

    private static void CheckPreview(OverlayWindow window, CapturedDisplay display, RectD selection, BitmapSource exported)
    {
        var surface = Surface(window);
        var preview = new RenderTargetBitmap(display.PixelWidth, display.PixelHeight, 96 * display.Scale, 96 * display.Scale, PixelFormats.Pbgra32);
        preview.Render(surface);
        // Ignore the selection outline and handles, but compare the complete
        // annotation interior, including effects over earlier vector marks.
        int inset = (int)(10 * display.Scale), left = (int)(selection.X * display.Scale), top = (int)(selection.Y * display.Scale);
        var region = new Int32Rect(inset, inset, exported.PixelWidth - inset * 2, exported.PixelHeight - inset * 2);
        var expected = new byte[region.Width * region.Height * 4];
        var actual = new byte[expected.Length];
        exported.CopyPixels(region, expected, region.Width * 4, 0);
        region.X += left; region.Y += top;
        preview.CopyPixels(region, actual, region.Width * 4, 0);
        Require(expected.SequenceEqual(actual), "redo live overlay interior matches exported pixels");
    }

    private static BitmapSource Export(OverlayWindow window, Func<BitmapSource?> latest)
    {
        Invoke(window, "Perform", CaptureAction.Copy);
        return latest() ?? throw new InvalidOperationException("Redo export did not reach the output callback");
    }

    private static bool Shortcut(OverlayWindow window, Key key, ModifierKeys modifiers)
        => (bool)Invoke(window, "HandleHistoryShortcut", key, modifiers)!;
    private static object? Invoke(OverlayWindow window, string method, params object[] arguments)
        => typeof(OverlayWindow).GetMethod(method, BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(window, arguments);
    private static OverlaySurface Surface(OverlayWindow window)
        => (OverlaySurface)typeof(OverlayWindow).GetField("surface", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(window)!;
    private static Button Button(OverlayWindow window, string tooltip)
        => Descendants((DependencyObject)window.Content).OfType<Button>().Single(button => Equals(button.ToolTip, tooltip));
    private static void Click(OverlayWindow window, string tooltip)
    {
        var button = Button(window, tooltip);
        Require(button.IsEnabled, $"{tooltip} is available for the fixture");
        button.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Button.ClickEvent));
    }

    private static BitmapSource Render(OverlayWindow window, CapturedDisplay display)
    {
        var root = (FrameworkElement)window.Content;
        root.Measure(new Size(display.Width, display.Height)); root.Arrange(new Rect(0, 0, display.Width, display.Height)); root.UpdateLayout();
        var bitmap = new RenderTargetBitmap(display.PixelWidth, display.PixelHeight, 96 * display.Scale, 96 * display.Scale, PixelFormats.Pbgra32);
        bitmap.Render(root); return bitmap;
    }
    private static void Save(BitmapSource image, string path) { using var stream = File.Create(path); OutputService.Encode(image, ImageFormat.Png, 1).Save(stream); }
    private static byte[] Bytes(BitmapSource image) { var bytes = new byte[image.PixelWidth * image.PixelHeight * 4]; image.CopyPixels(bytes, image.PixelWidth * 4, 0); return bytes; }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
        {
            var child = VisualTreeHelper.GetChild(parent, i);
            yield return child;
            foreach (var descendant in Descendants(child)) yield return descendant;
        }
    }
    private static CapturedDisplay Fixture(double scale)
    {
        int width = (int)(800 * scale), height = (int)(520 * scale);
        var pixels = new byte[width * height * 4];
        for (int y = 0; y < height; y++)
        for (int x = 0; x < width; x++)
        {
            int offset = (y * width + x) * 4;
            byte value = (byte)(((int)(x / scale) / 4 + (int)(y / scale) / 4) % 2 == 0 ? 30 : 220);
            pixels[offset] = value; pixels[offset + 1] = value; pixels[offset + 2] = value; pixels[offset + 3] = 255;
        }
        var image = BitmapSource.Create(width, height, 96 * scale, 96 * scale, PixelFormats.Pbgra32, null, pixels, width * 4); image.Freeze();
        return new(image, 0, 0, width, height, scale);
    }
    private static void Require(bool condition, string check) { if (!condition) throw new InvalidOperationException($"Windows redo smoke test failed: {check}"); }
}
