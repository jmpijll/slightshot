using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Slightshot.Core;

namespace Slightshot;

// One native-resolution selection cache. Pointer movement only processes the
// live effect's pixels; history and selection changes rebuild the composition.
internal sealed class AnnotationCompositor(CapturedDisplay display)
{
    private RectD? cachedSelection;
    private Annotation[] cachedHistory = [];
    private BitmapSource? cachedImage;
    private Annotation? cachedLive;
    private EffectPatch? cachedPatch;
    private Annotation? cachedStep;
    private BitmapSource? cachedStepImage;
    private sealed record EffectPatch(BitmapSource Image, Rect Bounds);

    public BitmapSource Committed(RectD selection, IReadOnlyList<Annotation> annotations)
    {
        if (cachedImage != null && cachedSelection == selection && cachedHistory.SequenceEqual(annotations)) return cachedImage;
        var sourcePixels = selection.ToPixels(display.PixelWidth / display.Width, display.PixelHeight / display.Height, display.PixelWidth, display.PixelHeight);
        var crop = new CroppedBitmap(display.Image, PixelRect(sourcePixels));
        BitmapSource image = Render(selection, dc => dc.DrawImage(crop, new Rect(0, 0, selection.Width, selection.Height)));
        var vectors = new List<Annotation>();
        foreach (var annotation in annotations)
        {
            if (!annotation.IsRasterEffect) { vectors.Add(annotation); continue; }
            image = DrawVectors(image, selection, vectors); vectors.Clear();
            if (Patch(image, selection, annotation) is not { } patch) continue;
            var previous = image;
            image = Render(selection, dc =>
            {
                dc.DrawImage(previous, ImageBounds(previous));
                var bounds = patch.Bounds; bounds.Offset(-selection.X, -selection.Y);
                dc.PushClip(new RectangleGeometry(new Rect(0, 0, selection.Width, selection.Height)));
                dc.DrawImage(patch.Image, bounds); dc.Pop();
            });
        }
        image = DrawVectors(image, selection, vectors);
        cachedImage = image; cachedSelection = selection; cachedHistory = annotations.ToArray(); cachedLive = null; cachedPatch = null;
        cachedStep = null; cachedStepImage = null;
        return image;
    }

    public void DrawLive(DrawingContext dc, RectD selection, Annotation annotation)
    {
        if (annotation.Tool == Tool.Step && cachedImage != null)
        {
            // WPF rounds antialiased edges differently when a vector draws
            // directly over the surface. A fixed stamp uses the export layer
            // path once per gesture, then reuses these exact preview pixels.
            if (cachedStep != annotation)
            {
                cachedStepImage = DrawVectors(cachedImage, selection, [annotation]);
                cachedStep = annotation;
            }
            if (cachedStepImage is { } image)
                dc.DrawImage(image, new Rect(selection.X, selection.Y, image.PixelWidth / display.Scale, image.PixelHeight / display.Scale));
            return;
        }
        if (!annotation.IsRasterEffect) { AnnotationRenderer.Draw(dc, annotation, display.Scale); return; }
        if (cachedImage == null) return;
        if (cachedLive != annotation) { cachedPatch = Patch(cachedImage, selection, annotation); cachedLive = annotation; }
        if (cachedPatch is { } patch) dc.DrawImage(patch.Image, patch.Bounds);
    }

    private BitmapSource DrawVectors(BitmapSource image, RectD selection, List<Annotation> annotations)
    {
        if (annotations.Count == 0) return image;
        return Render(selection, dc =>
        {
            dc.DrawImage(image, ImageBounds(image));
            dc.PushClip(new RectangleGeometry(new Rect(0, 0, selection.Width, selection.Height)));
            dc.PushTransform(new TranslateTransform(-selection.X, -selection.Y));
            foreach (var annotation in annotations) AnnotationRenderer.Draw(dc, annotation, display.Scale);
            dc.Pop(); dc.Pop();
        });
    }

    private BitmapSource Render(RectD selection, Action<DrawingContext> draw)
    {
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen()) draw(dc);
        var bitmap = new RenderTargetBitmap(Math.Max(1, (int)Math.Round(selection.Width * display.Scale)), Math.Max(1, (int)Math.Round(selection.Height * display.Scale)), 96 * display.Scale, 96 * display.Scale, PixelFormats.Pbgra32);
        bitmap.Render(visual); bitmap.Freeze(); return bitmap;
    }

    private EffectPatch? Patch(BitmapSource image, RectD selection, Annotation annotation)
    {
        if (RasterEffects.Region(annotation, selection) is not { } region) return null;
        var local = new RectD(region.X - selection.X, region.Y - selection.Y, region.Width, region.Height);
        var pixels = local.ToPixels(display.Scale, display.Scale, image.PixelWidth, image.PixelHeight);
        var output = PixelRect(pixels);
        int padding = annotation.Tool == Tool.Blur ? RasterEffects.BlurPadding(RasterEffects.BlurRadius * display.Scale) : 0;
        int left = Math.Max(0, output.X - padding), top = Math.Max(0, output.Y - padding);
        int right = Math.Min(image.PixelWidth, output.X + output.Width + padding), bottom = Math.Min(image.PixelHeight, output.Y + output.Height + padding);
        int width = right - left, height = bottom - top;
        var buffer = new byte[width * height * 4];
        image.CopyPixels(new Int32Rect(left, top, width, height), buffer, width * 4, 0);
        if (annotation.Tool == Tool.Blur) RasterEffects.Blur(buffer, width, height, RasterEffects.BlurRadius * display.Scale);
        else RasterEffects.Pixelate(buffer, width, height, Math.Max(1, (int)Math.Round(RasterEffects.PixelBlockSize * display.Scale)));
        var transformed = BitmapSource.Create(width, height, 96 * display.Scale, 96 * display.Scale, PixelFormats.Pbgra32, null, buffer, width * 4);
        var patch = new CroppedBitmap(transformed, new Int32Rect(output.X - left, output.Y - top, output.Width, output.Height)); patch.Freeze();
        return new(patch, new Rect(selection.X + output.X / display.Scale, selection.Y + output.Y / display.Scale, output.Width / display.Scale, output.Height / display.Scale));
    }

    private static Int32Rect PixelRect(RectD pixels) => new((int)pixels.X, (int)pixels.Y, (int)pixels.Width, (int)pixels.Height);
    // Rounded output dimensions can differ from the logical selection at
    // fractional DPI. Keep prior pixels at 1:1 size when adding a new layer.
    private Rect ImageBounds(BitmapSource image) => new(0, 0, image.PixelWidth / display.Scale, image.PixelHeight / display.Scale);
}
