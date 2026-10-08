using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Slightshot.Core;

namespace Slightshot;

internal static class StepSmokeTest
{
    internal static void Run(string directory, List<string> checks)
    {
        Require(Enum.GetValues<Tool>().Length == 9, "nine annotation tools remain available");
        foreach (double scale in new[] { 1.0, 1.25, 1.5, 2.0 })
        {
            int width = (int)(120 * scale), height = (int)(100 * scale);
            var pixels = new byte[width * height * 4];
            for (int i = 3; i < pixels.Length; i += 4) pixels[i] = 255;
            var image = BitmapSource.Create(width, height, 96 * scale, 96 * scale, PixelFormats.Pbgra32, null, pixels, width * 4); image.Freeze();
            var display = new CapturedDisplay(image, 0, 0, width, height, scale);
            RectD selection = new(8, 8, 96, 72);
            var step = new Annotation(Tool.Step, [new(56, 44)], "#FF0000", 3, StepNumber: 12);
            var original = AnnotationRenderer.Flatten(display, selection, [step], true);
            Require(Pixel(original, (int)(58 * scale), (int)(36 * scale)).R > 240, $"step uses current colour @{scale}");
            Require(Bytes(original).SequenceEqual(Bytes(AnnotationRenderer.Flatten(display, selection, [step with { Width = 12, FontSize = 40 }], true))), $"step ignores thickness and text size @{scale}");
            Require(!Bytes(original).SequenceEqual(Bytes(AnnotationRenderer.Flatten(display, selection, [step with { StepNumber = 100 }], true))), $"multi-digit stamp grows and displays its number @{scale}");
            foreach (Tool tool in new[] { Tool.Blur, Tool.Pixelate })
            {
                var effect = new Annotation(tool, [new(16, 16), new(96, 80)], "#00FF00", 3);
                var before = AnnotationRenderer.Flatten(display, selection, [step, effect], true);
                var after = AnnotationRenderer.Flatten(display, selection, [effect, step], true);
                Require(!Bytes(before).SequenceEqual(Bytes(after)), $"{tool} transforms earlier steps and preserves later steps @{scale}");
                CheckSurface(directory, display, selection, [step, effect], step with { Points = [new(76, 56)], StepNumber = 100 });
            }
            CheckSurface(directory, display, selection, [], step);

            var clipped = step with { Points = [new(10, 44)], StepNumber = 1 };
            var output = AnnotationRenderer.Flatten(display, selection, [clipped], true);
            Require(output.PixelWidth == (int)(96 * scale) && output.PixelHeight == (int)(72 * scale), $"stamp clips to selection @{scale}");
            var surface = Surface(display, selection, [clipped], null);
            Require(Pixel(Render(surface, display), (int)(2 * scale), (int)(44 * scale)).R == 0, $"stamp leaves outside selection untouched @{scale}");
            var white = step with { Color = "#FFFFFF", StepNumber = 1 };
            var light = AnnotationRenderer.Flatten(display, selection, [white], true);
            var glyph = new CroppedBitmap(light, new Int32Rect((int)(44 * scale), (int)(30 * scale), (int)(8 * scale), (int)(12 * scale)));
            Require(Bytes(glyph).Where((_, i) => i % 4 != 3).Any(channel => channel < 80), $"light-colour stamp has contrasting dark digits @{scale}");
            var logical = AnnotationRenderer.Flatten(display, selection, [step], false);
            Require(logical.PixelWidth == 96 && logical.PixelHeight == 72, $"logical step export size @{scale}");
            using var stream = File.Create(Path.Combine(directory, $"steps-{scale:0.##}x.png")); OutputService.Encode(original, ImageFormat.Png, 1).Save(stream);
            checks.Add($"{scale:0.##}× numbered steps: current colour, fixed readable sizing, multi-digit labels, clipped/live/committed/export pixels, raster ordering and undo passed");
        }
    }

    private static void CheckSurface(string directory, CapturedDisplay display, RectD selection, Annotation[] history, Annotation live)
    {
        var exported = AnnotationRenderer.Flatten(display, selection, history.Append(live), true);
        var surface = Surface(display, selection, history, live);
        var preview = Render(surface, display);
        surface.Annotations.Add(live); surface.LiveAnnotation = null; surface.InvalidateVisual(); surface.UpdateLayout();
        var committed = Render(surface, display);
        var mismatches = new List<string>();
        int differences = 0;
        // Compare the interior, excluding the selection border and handles.
        for (int y = (int)(12 * display.Scale); y < (int)(60 * display.Scale); y++)
        for (int x = (int)(12 * display.Scale); x < (int)(84 * display.Scale); x++)
        {
            int offset = (int)(8 * display.Scale);
            var expected = Pixel(exported, x, y);
            var current = Pixel(preview, x + offset, y + offset);
            var retained = Pixel(committed, x + offset, y + offset);
            if (current == expected && retained == expected) continue;
            differences++;
            if (mismatches.Count < 12) mismatches.Add($"{x},{y}: live={current}, committed={retained}, export={expected}");
        }
        if (differences > 0)
        {
            Save(preview, Path.Combine(directory, $"step-failure-live-{display.Scale:0.##}x.png"));
            Save(committed, Path.Combine(directory, $"step-failure-committed-{display.Scale:0.##}x.png"));
            Save(exported, Path.Combine(directory, $"step-failure-export-{display.Scale:0.##}x.png"));
            throw new InvalidOperationException($"Step pixel parity @{display.Scale}, history={string.Join(',', history.Select(annotation => annotation.Tool))}, {differences} mismatches: {string.Join(';', mismatches)}");
        }
        surface.Annotations.Undo(); surface.InvalidateVisual(); surface.UpdateLayout();
        var undone = Render(surface, display);
        var restored = AnnotationRenderer.Flatten(display, selection, history, true);
        int px = (int)((live.Points[0].X + 10 - selection.X) * display.Scale), py = (int)((live.Points[0].Y - selection.Y) * display.Scale);
        Require(Pixel(undone, px + (int)(8 * display.Scale), py + (int)(8 * display.Scale)) == Pixel(restored, px, py), $"undo restores pixels beneath step @{display.Scale}");
    }

    private static OverlaySurface Surface(CapturedDisplay display, RectD selection, Annotation[] history, Annotation? live)
    {
        var surface = new OverlaySurface(display, new Settings { ShowDimensions = false, ShowMagnifier = false }) { Selection = selection, LiveAnnotation = live };
        surface.Annotations.AddRange(history); surface.Measure(new Size(120, 100)); surface.Arrange(new Rect(0, 0, 120, 100)); surface.UpdateLayout();
        return surface;
    }

    private static BitmapSource Render(OverlaySurface surface, CapturedDisplay display)
    {
        var bitmap = new RenderTargetBitmap(display.PixelWidth, display.PixelHeight, 96 * display.Scale, 96 * display.Scale, PixelFormats.Pbgra32);
        bitmap.Render(surface); return bitmap;
    }
    private static byte[] Bytes(BitmapSource image) { var bytes = new byte[image.PixelWidth * image.PixelHeight * 4]; image.CopyPixels(bytes, image.PixelWidth * 4, 0); return bytes; }
    private static void Save(BitmapSource image, string path) { using var stream = File.Create(path); OutputService.Encode(image, ImageFormat.Png, 1).Save(stream); }
    private static Color Pixel(BitmapSource image, int x, int y) { byte[] pixel = new byte[4]; image.CopyPixels(new Int32Rect(x, y, 1, 1), pixel, 4, 0); return Color.FromArgb(pixel[3], pixel[2], pixel[1], pixel[0]); }
    private static void Require(bool condition, string check) { if (!condition) throw new InvalidOperationException($"Windows numbered step smoke test failed: {check}"); }
}
