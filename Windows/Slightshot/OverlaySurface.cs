using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Slightshot.Core;

namespace Slightshot;

internal sealed class OverlaySurface(CapturedDisplay display, Settings settings) : FrameworkElement
{
    private readonly AnnotationCompositor compositor = new(display);
    public RectD? Selection { get; set; }
    public List<Annotation> Annotations { get; } = [];
    public Annotation? LiveAnnotation { get; set; }
    public bool ShowHint { get; set; }
    public PointD? MagnifierPoint { get; set; }
    protected override void OnRender(DrawingContext dc)
    {
        double scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
        dc.DrawImage(display.Image, new Rect(0, 0, ActualWidth, ActualHeight));
        Geometry veil = new RectangleGeometry(new Rect(0, 0, ActualWidth, ActualHeight));
        if (Selection is { } selection) veil = new CombinedGeometry(GeometryCombineMode.Exclude, veil, new RectangleGeometry(AnnotationRenderer.Rect(selection)));
        dc.DrawGeometry(AnnotationRenderer.Brush("#000000", settings.DimOpacity), null, veil);
        if (Selection is { Width: >= 1, Height: >= 1 } r)
        {
            dc.PushClip(new RectangleGeometry(AnnotationRenderer.Rect(r)));
            if (Annotations.Any(a => a.IsRasterEffect || a.Tool == Tool.Step) ||
                LiveAnnotation is { IsRasterEffect: true } or { Tool: Tool.Step })
            {
                var composition = compositor.Committed(r, Annotations);
                dc.DrawImage(composition, new Rect(r.X, r.Y, composition.PixelWidth / display.Scale, composition.PixelHeight / display.Scale));
                if (LiveAnnotation != null) compositor.DrawLive(dc, r, LiveAnnotation);
            }
            else
            {
                foreach (var annotation in Annotations) AnnotationRenderer.Draw(dc, annotation, scale);
                if (LiveAnnotation != null) AnnotationRenderer.Draw(dc, LiveAnnotation, scale);
            }
            dc.Pop();
            var outline = AnnotationRenderer.Rect(r); outline.Inflate(0.5 / scale, 0.5 / scale);
            dc.DrawRectangle(null, new Pen(AnnotationRenderer.Brush("#FFFFFF", 0.95), 2 / scale), outline);
            foreach (var handle in Enum.GetValues<SelectionHandle>())
            {
                var anchor = handle.Anchor(r);
                dc.DrawRectangle(Brushes.White, new Pen(AnnotationRenderer.Brush("#000000", 0.45), 1 / scale), new Rect(anchor.X - 3.5, anchor.Y - 3.5, 7, 7));
            }
            if (settings.ShowDimensions)
            {
                var text = AnnotationRenderer.Text($"{Math.Round(r.Width)} × {Math.Round(r.Height)}", 11, Brushes.White, scale, true);
                double width = text.Width + 14, height = text.Height + 6;
                double x = OverlayStyle.Fit(r.Left, width, ActualWidth, 2), y = r.Top - height - 5;
                if (y < 2) y = r.Top + 5;
                dc.DrawRoundedRectangle(AnnotationRenderer.Brush("#000000", 0.72), null, new Rect(x, y, width, height), 4, 4);
                dc.DrawText(text, new(x + 7, y + 3));
            }
        }
        else if (ShowHint)
        {
            var text = AnnotationRenderer.Text("Drag to select an area  ·  Esc to cancel", 13, AnnotationRenderer.Brush("#FFFFFF", 0.9), scale);
            double x = (ActualWidth - text.Width) / 2 - 14, y = ActualHeight * 0.14 - text.Height / 2 - 8;
            dc.DrawRoundedRectangle(AnnotationRenderer.Brush("#000000", 0.6), null, new Rect(x, y, text.Width + 28, text.Height + 16), 9, 9);
            dc.DrawText(text, new(x + 14, y + 8));
        }
        if (settings.ShowMagnifier && MagnifierPoint is { } point) DrawMagnifier(dc, point, scale);
    }

    private void DrawMagnifier(DrawingContext dc, PointD point, double pixelsPerDip)
    {
        const double side = 136, height = 174, cell = 8;
        double x = point.X + 18, y = point.Y + 18;
        if (x + side > ActualWidth - 6) x = point.X - 18 - side;
        if (y + height > ActualHeight - 6) y = point.Y - 18 - height;
        x = OverlayStyle.Fit(x, side, ActualWidth, 6); y = OverlayStyle.Fit(y, height, ActualHeight, 6);
        dc.PushTransform(new TranslateTransform(x, y));
        dc.PushClip(new RectangleGeometry(new Rect(0, 0, side, height), 8, 8));
        dc.DrawRectangle(Brushes.Black, null, new Rect(0, 0, side, height));
        int px = Math.Clamp((int)Math.Floor(point.X * display.Scale), 0, display.PixelWidth - 1), py = Math.Clamp((int)Math.Floor(point.Y * display.Scale), 0, display.PixelHeight - 1);
        int left = Math.Max(0, px - 8), top = Math.Max(0, py - 8), right = Math.Min(display.PixelWidth, px + 9), bottom = Math.Min(display.PixelHeight, py + 9);
        var crop = new CroppedBitmap(display.Image, new Int32Rect(left, top, right - left, bottom - top));
        var image = new DrawingImage(new ImageDrawing(crop, new Rect((left - px + 8) * cell, (top - py + 8) * cell, (right - left) * cell, (bottom - top) * cell)));
        RenderOptions.SetBitmapScalingMode(image, BitmapScalingMode.NearestNeighbor);
        // Applying nearest-neighbour to this surface also keeps the loupe cells crisp.
        dc.DrawImage(image, new Rect((left - px + 8) * cell, (top - py + 8) * cell, (right - left) * cell, (bottom - top) * cell));
        var gridPen = new Pen(AnnotationRenderer.Brush("#FFFFFF", 0.12), 1 / pixelsPerDip);
        for (int i = 1; i < 17; i++) { dc.DrawLine(gridPen, new(i * cell, 0), new(i * cell, side)); dc.DrawLine(gridPen, new(0, i * cell), new(side, i * cell)); }
        dc.DrawRectangle(null, new Pen(AnnotationRenderer.Brush(settings.AnnotationColor), 1.5), new Rect(63.5, 63.5, 9, 9));
        dc.DrawRectangle(AnnotationRenderer.Brush("#000000", 0.92), null, new Rect(0, 136, side, 38));
        dc.DrawText(AnnotationRenderer.Text($"{Math.Round(point.X)}, {Math.Round(point.Y)}", 11, Brushes.White, pixelsPerDip, true), new(8, 138));
        var colorSource = new FormatConvertedBitmap(display.Image, PixelFormats.Bgra32, null, 0); byte[] pixel = new byte[4];
        colorSource.CopyPixels(new Int32Rect(px, py, 1, 1), pixel, 4, 0);
        string hex = $"#{pixel[2]:X2}{pixel[1]:X2}{pixel[0]:X2}";
        dc.DrawRoundedRectangle(AnnotationRenderer.Brush(hex), new Pen(AnnotationRenderer.Brush("#FFFFFF", 0.5), 1), new Rect(8, 158, 11, 11), 2, 2);
        dc.DrawText(AnnotationRenderer.Text(hex, 11, AnnotationRenderer.Brush("#FFFFFF", 0.85), pixelsPerDip, true), new(25, 157));
        dc.Pop(); dc.DrawRoundedRectangle(null, new Pen(AnnotationRenderer.Brush("#FFFFFF", 0.35), 1), new Rect(0, 0, side, height), 8, 8); dc.Pop();
    }
}
