using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Slightshot.Core;

namespace Slightshot;

internal static class RasterEffectSmokeTest
{
    public static void Run(string directory, List<string> checks)
    {
        FractionalSelectionChecks(checks);
        foreach (double scale in new[] { 1.0, 1.25, 1.5, 2.0 })
        {
            int width = (int)(120 * scale), height = (int)(100 * scale);
            var pixels = new byte[width * height * 4];
            for (int y = 0; y < height; y++)
            for (int x = 0; x < width; x++)
            {
                byte shade = (byte)((x + y) % 2 == 0 ? 0 : 255);
                int offset = (y * width + x) * 4;
                pixels[offset] = pixels[offset + 1] = pixels[offset + 2] = shade; pixels[offset + 3] = 255;
            }
            var image = BitmapSource.Create(width, height, 96 * scale, 96 * scale, PixelFormats.Pbgra32, null, pixels, width * 4); image.Freeze();
            var display = new CapturedDisplay(image, 0, 0, width, height, scale);
            // Coordinates align to physical pixels at every fixture DPI.
            RectD selection = new(8, 8, 96, 72);
            var red = new Annotation(Tool.Line, [new(8, 40), new(104, 40)], "#FF0000", 2);
            var blue = new Annotation(Tool.Line, [new(8, 40), new(104, 40)], "#0000FF", 2);
            var original = AnnotationRenderer.Flatten(display, selection, [red], true);
            foreach (var tool in new[] { Tool.Blur, Tool.Pixelate })
            {
                var effect = new Annotation(tool, [new(28, 28), new(64, 64)], "#00FF00", 11);
                var transformed = AnnotationRenderer.Flatten(display, selection, [red, effect], true);
                int px = (int)(36 * scale), py = (int)(32 * scale);
                var before = Pixel(original, px, py); var after = Pixel(transformed, px, py);
                Require(before.R > 240 && after.R < 235 && after.G > 10, $"{tool} changes preceding annotation pixels @{scale}");
                int outsideX = (int)(8 * scale), outsideY = (int)(8 * scale);
                Require(Pixel(original, outsideX, outsideY) == Pixel(transformed, outsideX, outsideY), $"{tool} leaves outside pixels unchanged @{scale}");
                var reverse = effect with { Points = [new(64, 64), new(28, 28)] };
                Require(Bytes(transformed).SequenceEqual(Bytes(AnnotationRenderer.Flatten(display, selection, [red, reverse], true))), $"reverse {tool} drag produces the same rectangle @{scale}");
                var later = AnnotationRenderer.Flatten(display, selection, [red, effect, blue], true);
                Require(Pixel(later, px, py).B > 240 && Pixel(later, px, py).R < 10, $"{tool} preserves later annotation order @{scale}");
                var clipped = effect with { Points = [new(-30, -30), new(40, 40)] };
                var clippedOutput = AnnotationRenderer.Flatten(display, selection, [clipped], true);
                var zero = effect with { Points = [new(30, 30), new(30, 50)] };
                var emptyOutput = AnnotationRenderer.Flatten(display, selection, [zero], true);
                Require(Bytes(emptyOutput).SequenceEqual(Bytes(AnnotationRenderer.Flatten(display, selection, [], true))), $"zero-width {tool} is unchanged @{scale}");
                Require(clippedOutput.PixelWidth == (int)(96 * scale) && clippedOutput.PixelHeight == (int)(72 * scale), $"{tool} clips at selection boundary @{scale}");
                Require(Pixel(clippedOutput, (int)(64 * scale), (int)(56 * scale)) == Pixel(AnnotationRenderer.Flatten(display, selection, [], true), (int)(64 * scale), (int)(56 * scale)), $"clipped {tool} leaves the far side unchanged @{scale}");

                // Exercise the exact surface path used while dragging: committed
                // history comes from the cache and the live ROI draws above it.
                var surface = new OverlaySurface(display.Source, new Settings { ShowDimensions = false, ShowMagnifier = false }) { Selection = selection, LiveAnnotation = effect };
                surface.Annotations.Add(red);
                surface.Measure(new Size(120, 100)); surface.Arrange(new Rect(0, 0, 120, 100)); surface.UpdateLayout();
                var preview = new RenderTargetBitmap(width, height, 96 * scale, 96 * scale, PixelFormats.Pbgra32); preview.Render(surface);
                var previewPixel = Pixel(preview, px + (int)(8 * scale), py + (int)(8 * scale));
                Require(previewPixel == after, $"live {tool} matches native exported pixels @{scale}");
                surface.Annotations.Add(effect); surface.LiveAnnotation = null; surface.InvalidateVisual(); surface.UpdateLayout();
                var committed = new RenderTargetBitmap(width, height, 96 * scale, 96 * scale, PixelFormats.Pbgra32); committed.Render(surface);
                Require(Pixel(committed, px + (int)(8 * scale), py + (int)(8 * scale)) == after, $"committed {tool} matches live preview @{scale}");
                surface.Annotations.Undo(); surface.InvalidateVisual(); surface.UpdateLayout();
                var undone = new RenderTargetBitmap(width, height, 96 * scale, 96 * scale, PixelFormats.Pbgra32); undone.Render(surface);
                Require(Pixel(undone, px + (int)(8 * scale), py + (int)(8 * scale)) == before, $"undo restores pixels after {tool} @{scale}");
                Require(Bytes(image).SequenceEqual(pixels), $"{tool} keeps frozen source unchanged @{scale}");
                var logical = AnnotationRenderer.Flatten(display, selection, [red, effect], false);
                Require(logical.PixelWidth == 96 && logical.PixelHeight == 72, $"{tool} logical export dimensions @{scale}");
                using var stream = File.Create(Path.Combine(directory, $"{tool.ToString().ToLowerInvariant()}-{scale:0.##}x.png")); OutputService.Encode(transformed, ImageFormat.Png, 1).Save(stream);
            }
            checks.Add($"{scale:0.##}× effects: source pixels transformed, ordered annotations, clipped/empty regions, live/committed/export parity, undo and logical export passed");
        }
    }

    private static void FractionalSelectionChecks(List<string> checks)
    {
        foreach (double scale in new[] { 1.0, 1.25, 1.5, 2.0 })
        {
            int width = (int)(120 * scale), height = (int)(100 * scale);
            var pixels = new byte[width * height * 4];
            for (int y = 0; y < height; y++)
            for (int x = 0; x < width; x++)
            {
                int offset = (y * width + x) * 4;
                pixels[offset] = (byte)((7 * x + 19 * y * y) % 256);
                pixels[offset + 1] = (byte)((x * x + 11 * y) % 256);
                pixels[offset + 2] = (byte)((17 * x + 31 * y) % 256);
                pixels[offset + 3] = 255;
            }
            var image = BitmapSource.Create(width, height, 96 * scale, 96 * scale, PixelFormats.Pbgra32, null, pixels, width * 4); image.Freeze();
            var display = new CapturedDisplay(image, 0, 0, width, height, scale);
            RectD selection = new(8.2, 11.7, 93.4, 71.1);
            var line = new Annotation(Tool.Line, [new(12.3, 20.6), new(96.4, 66.7)], "#E13476", 2.3);
            Annotation[] history = [line];
            var baseline = AnnotationRenderer.Flatten(display, selection, history, true);
            var original = Bytes(baseline);
            foreach (var tool in new[] { Tool.Blur, Tool.Pixelate })
            {
                var effect = new Annotation(tool, [new(32.8, 30), new(40.7, 40.7)], "#FF0000", 3);
                var transformed = AnnotationRenderer.Flatten(display, selection, [line, effect], true);
                var edited = Bytes(transformed);
                // Hand-derived coverage of this fractional rectangle; do not
                // call production geometry to decide which pixels to verify.
                int left = (int)Math.Floor((32.8 - 8.2) * scale), top = (int)Math.Floor((30 - 11.7) * scale);
                int right = (int)Math.Ceiling((40.7 - 8.2) * scale), bottom = (int)Math.Ceiling((40.7 - 11.7) * scale);
                bool changedInside = false;
                for (int y = 0; y < baseline.PixelHeight; y++)
                for (int x = 0; x < baseline.PixelWidth; x++)
                for (int channel = 0; channel < 4; channel++)
                {
                    int offset = (y * baseline.PixelWidth + x) * 4 + channel;
                    bool inside = x >= left && x < right && y >= top && y < bottom;
                    if (inside) changedInside |= original[offset] != edited[offset];
                    else Require(original[offset] == edited[offset], $"fractional {tool} changes outside pixel ({x}, {y}), channel {channel} @{scale}");
                }
                Require(changedInside, $"fractional {tool} transforms its ROI @{scale}");
                var compositor = new AnnotationCompositor(display.Source);
                var committed = compositor.Committed(selection, history);
                var visual = new DrawingVisual();
                using (var dc = visual.RenderOpen())
                {
                    dc.DrawImage(committed, new Rect(0, 0, committed.PixelWidth / scale, committed.PixelHeight / scale));
                    dc.PushTransform(new TranslateTransform(-selection.X, -selection.Y));
                    compositor.DrawLive(dc, selection, effect); dc.Pop();
                }
                var live = new RenderTargetBitmap(baseline.PixelWidth, baseline.PixelHeight, 96 * scale, 96 * scale, PixelFormats.Pbgra32); live.Render(visual);
                Require(Bytes(live).SequenceEqual(edited), $"fractional live {tool} matches every exported pixel @{scale}");
            }
            checks.Add($"{scale:0.##}× fractional origin/size: tiny blur/pixelate leave every outside BGRA pixel unchanged; every live/export pixel matches");
        }
    }

    private static byte[] Bytes(BitmapSource image)
    {
        var converted = new FormatConvertedBitmap(image, PixelFormats.Pbgra32, null, 0);
        var pixels = new byte[image.PixelWidth * image.PixelHeight * 4]; converted.CopyPixels(pixels, image.PixelWidth * 4, 0); return pixels;
    }
    private static Color Pixel(BitmapSource image, int x, int y)
    {
        var converted = new FormatConvertedBitmap(image, PixelFormats.Bgra32, null, 0); byte[] pixel = new byte[4];
        converted.CopyPixels(new Int32Rect(x, y, 1, 1), pixel, 4, 0); return Color.FromArgb(pixel[3], pixel[2], pixel[1], pixel[0]);
    }
    private static void Require(bool condition, string check) { if (!condition) throw new InvalidOperationException($"Windows raster effect smoke test failed: {check}"); }
}
