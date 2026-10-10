using System.Buffers;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Slightshot.Core;

namespace Slightshot;

// Video changes its background every frame, but annotation glyphs do not.
// Cache only the currently active vector layers. Effects edit their pixel ROI
// in place, preserving drawing order without multiple full-frame WPF copies.
internal sealed class VideoPixelCompositor(int width, int height) : IDisposable
{
    private sealed record VectorPatch(Int32Rect Bounds, byte[] Pixels);
    private sealed record Layer(Annotation? Effect, VectorPatch? Vector);
    private TimedAnnotation[] active = [];
    private readonly List<Layer> layers = [];
    private byte[]? scratch;
    internal void Render(byte[] pixels, TimeSpan position, IReadOnlyList<TimedAnnotation> annotations, CancellationToken cancellation)
    {
        var visible = annotations.Where(item => item.IsVisible(position)).ToArray();
        if (!active.SequenceEqual(visible))
        {
            layers.Clear(); var vectors = new List<Annotation>();
            void Flush()
            {
                if (vectors.Count == 0) return;
                if (MakeVectorPatch(vectors) is { } patch) layers.Add(new(null, patch));
                vectors.Clear();
            }
            foreach (var mark in visible)
            {
                if (!mark.Annotation.IsRasterEffect) { vectors.Add(mark.Annotation); continue; }
                Flush(); layers.Add(new(mark.Annotation, null));
            }
            Flush(); active = visible;
        }
        foreach (var layer in layers)
        {
            cancellation.ThrowIfCancellationRequested();
            if (layer.Effect is { } effect) ApplyEffect(pixels, effect);
            else if (layer.Vector is { } vector) Blend(pixels, vector);
        }
    }
    private VectorPatch? MakeVectorPatch(IReadOnlyList<Annotation> annotations)
    {
        var drawing = new DrawingVisual();
        using (var dc = drawing.RenderOpen()) foreach (var annotation in annotations) AnnotationRenderer.Draw(dc, annotation);
        var bounds = drawing.ContentBounds; bounds.Inflate(1, 1); bounds.Intersect(new Rect(0, 0, width, height));
        if (bounds.IsEmpty || bounds.Width <= 0 || bounds.Height <= 0) return null;
        int left = Math.Max(0, (int)Math.Floor(bounds.Left)), top = Math.Max(0, (int)Math.Floor(bounds.Top));
        int right = Math.Min(width, (int)Math.Ceiling(bounds.Right)), bottom = Math.Min(height, (int)Math.Ceiling(bounds.Bottom));
        var rect = new Int32Rect(left, top, right - left, bottom - top);
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            dc.PushTransform(new TranslateTransform(-left, -top));
            dc.DrawDrawing(drawing.Drawing); dc.Pop();
        }
        var image = new RenderTargetBitmap(rect.Width, rect.Height, 96, 96, PixelFormats.Pbgra32);
        image.Render(visual);
        var pixels = new byte[checked(rect.Width * rect.Height * 4)]; image.CopyPixels(pixels, rect.Width * 4, 0);
        return new(rect, pixels);
    }
    private void ApplyEffect(byte[] pixels, Annotation effect)
    {
        if (RasterEffects.Region(effect, new(0, 0, width, height)) is not { } region) return;
        var output = region.ToPixels(1, 1, width, height);
        double radius = RasterEffects.BlurRadius * effect.EffectiveRasterScale;
        int padding = effect.Tool == Tool.Blur ? RasterEffects.BlurPadding(radius) : 0;
        int left = Math.Max(0, (int)output.X - padding), top = Math.Max(0, (int)output.Y - padding);
        int right = Math.Min(width, (int)output.Right + padding), bottom = Math.Min(height, (int)output.Bottom + padding);
        int patchWidth = right - left, patchHeight = bottom - top;
        int required = checked(patchWidth * patchHeight * 4);
        if (scratch == null || scratch.Length < required)
        {
            if (scratch != null) ArrayPool<byte>.Shared.Return(scratch);
            scratch = ArrayPool<byte>.Shared.Rent(required);
        }
        for (int row = 0; row < patchHeight; row++)
            Buffer.BlockCopy(pixels, ((top + row) * width + left) * 4, scratch, row * patchWidth * 4, patchWidth * 4);
        if (effect.Tool == Tool.Blur) RasterEffects.Blur(scratch, patchWidth, patchHeight, radius);
        else RasterEffects.Pixelate(scratch, patchWidth, patchHeight, Math.Max(1, (int)Math.Round(RasterEffects.PixelBlockSize * effect.EffectiveRasterScale)));
        for (int row = 0; row < (int)output.Height; row++)
            Buffer.BlockCopy(scratch, (((int)output.Y - top + row) * patchWidth + (int)output.X - left) * 4,
                pixels, (((int)output.Y + row) * width + (int)output.X) * 4, (int)output.Width * 4);
    }
    private void Blend(byte[] pixels, VectorPatch patch)
    {
        for (int y = 0; y < patch.Bounds.Height; y++)
        {
            int target = ((patch.Bounds.Y + y) * width + patch.Bounds.X) * 4;
            int source = y * patch.Bounds.Width * 4;
            for (int x = 0; x < patch.Bounds.Width; x++, target += 4, source += 4)
            {
                int alpha = patch.Pixels[source + 3];
                if (alpha == 0) continue;
                for (int channel = 0; channel < 3; channel++)
                    pixels[target + channel] = (byte)(patch.Pixels[source + channel] + (pixels[target + channel] * (255 - alpha) + 127) / 255);
            }
        }
    }
    public void Dispose() { if (scratch != null) { ArrayPool<byte>.Shared.Return(scratch); scratch = null; } layers.Clear(); active = []; }
}
