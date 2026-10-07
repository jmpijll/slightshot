using System.Globalization;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Slightshot.Core;

namespace Slightshot;

internal static class AnnotationRenderer
{
    internal static SolidColorBrush Brush(string hex, double alpha = 1)
    {
        var color = (Color)ColorConverter.ConvertFromString(hex);
        color.A = (byte)Math.Round(255 * alpha);
        var brush = new SolidColorBrush(color); brush.Freeze(); return brush;
    }
    internal static Point Point(PointD p) => new(p.X, p.Y);
    internal static Rect Rect(RectD r) => new(r.X, r.Y, Math.Max(0, r.Width), Math.Max(0, r.Height));
    internal static FormattedText Text(string text, double size, Brush brush, double pixelsPerDip = 1, bool monospace = false) => new(text, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, new Typeface(new FontFamily(monospace ? "Consolas" : "Segoe UI"), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal), size, brush, pixelsPerDip);

    public static void Draw(DrawingContext dc, Annotation annotation, double pixelsPerDip = 1)
    {
        var points = annotation.Points;
        if (points.Length == 0) return;
        var brush = Brush(annotation.Color, annotation.Alpha);
        double width = annotation.EffectiveWidth;
        var pen = new Pen(brush, width) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round }; pen.Freeze();
        Point start = Point(points[0]), end = Point(points[^1]);
        switch (annotation.Tool)
        {
            case Tool.Pen:
            case Tool.Marker:
                if (points.Length == 1) { dc.DrawEllipse(brush, null, start, width / 2, width / 2); break; }
                var stroke = new StreamGeometry();
                using (var path = stroke.Open())
                {
                    path.BeginFigure(start, false, false);
                    if (points.Length == 2) path.LineTo(end, true, false);
                    else for (int i = 0; i < points.Length - 1; i++)
                    {
                        var p0 = points[Math.Max(i - 1, 0)]; var p1 = points[i]; var p2 = points[i + 1]; var p3 = points[Math.Min(i + 2, points.Length - 1)];
                        path.BezierTo(new(p1.X + (p2.X - p0.X) / 6, p1.Y + (p2.Y - p0.Y) / 6), new(p2.X - (p3.X - p1.X) / 6, p2.Y - (p3.Y - p1.Y) / 6), Point(p2), true, false);
                    }
                }
                stroke.Freeze(); dc.DrawGeometry(null, pen, stroke); break;
            case Tool.Line: dc.DrawLine(pen, start, end); break;
            case Tool.Arrow:
                double dx = end.X - start.X, dy = end.Y - start.Y, length = Math.Sqrt(dx * dx + dy * dy);
                if (length < 0.5) break;
                double headLength = Math.Min(Math.Max(width * 4.5, 10), length), headWidth = headLength * 0.62;
                double ux = dx / length, uy = dy / length;
                var @base = new Point(end.X - ux * headLength, end.Y - uy * headLength);
                dc.DrawLine(pen, start, new(end.X - ux * headLength * 0.75, end.Y - uy * headLength * 0.75));
                var head = new StreamGeometry();
                using (var path = head.Open()) { path.BeginFigure(end, true, true); path.LineTo(new(@base.X - uy * headWidth / 2, @base.Y + ux * headWidth / 2), true, false); path.LineTo(new(@base.X + uy * headWidth / 2, @base.Y - ux * headWidth / 2), true, false); }
                head.Freeze(); dc.DrawGeometry(brush, null, head); break;
            case Tool.Rectangle:
                var rectangle = Rect(RectD.Between(points[0], points[^1]));
                if (rectangle.Width < width || rectangle.Height < width) break;
                rectangle.Inflate(-width / 2, -width / 2);
                dc.DrawRectangle(null, new Pen(brush, width), rectangle); break;
            case Tool.Text:
                // The same two-pass text rendering is used live and in exported pixels.
                dc.DrawText(Text(annotation.Text, annotation.FontSize, Brush("#000000", 0.55), pixelsPerDip), new(start.X, start.Y + 1));
                dc.DrawText(Text(annotation.Text, annotation.FontSize, brush, pixelsPerDip), start); break;
        }
    }

    public static BitmapSource Flatten(CapturedDisplay display, RectD selection, IEnumerable<Annotation> annotations, bool nativeResolution)
    {
        var composed = new AnnotationCompositor(display).Committed(selection, annotations.ToArray());
        if (nativeResolution) return composed;
        int width = Math.Max(1, (int)Math.Round(selection.Width)), height = Math.Max(1, (int)Math.Round(selection.Height));
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
            dc.DrawImage(composed, new Rect(0, 0, selection.Width, selection.Height));
        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual); bitmap.Freeze(); return bitmap;
    }
}
