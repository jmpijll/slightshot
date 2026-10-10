using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Slightshot.Core;

namespace Slightshot;

// Viewbox scales this native-pixel canvas uniformly. Mouse coordinates arrive
// back in source pixels, so resizing the window never changes mark placement.
internal sealed class VideoAnnotationSurface : FrameworkElement
{
    private readonly VideoAnnotationHistory history;
    private readonly Settings settings;
    private BitmapSource? frame;
    private BitmapSource? composition;
    private Annotation? live;
    private PointD anchor;
    private readonly List<PointD> points = [];
    internal TimeSpan Position { get; set; }
    internal Tool? ActiveTool { get; set; }
    internal Action<Annotation>? AnnotationCreated { get; set; }
    internal Action<Guid?>? SelectionRequested { get; set; }
    internal Action<PointD>? TextRequested { get; set; }
    internal Action? PauseRequested { get; set; }
    internal double ViewScale { get; set; } = 1;
    internal BitmapSource? CurrentFrame => frame;
    internal VideoAnnotationSurface(VideoAnnotationHistory history, Settings settings, int width, int height)
    {
        this.history = history; this.settings = settings;
        Width = width; Height = height; Focusable = true; Cursor = Cursors.Arrow;
    }
    internal void SetFrame(BitmapSource image) { frame = image; Refresh(); }
    internal void Refresh() { composition = null; InvalidateVisual(); }
    protected override void OnRender(DrawingContext dc)
    {
        if (frame == null) { dc.DrawRectangle(Brushes.Black, null, new Rect(0, 0, Width, Height)); return; }
        if (composition == null)
        {
            var annotations = history.Items.ToList();
            if (live != null) annotations.Add(new(Guid.Empty, live, TimeSpan.Zero, history.Duration));
            composition = VideoAnnotationRenderer.Render(frame, Position, annotations);
        }
        dc.DrawImage(composition, new Rect(0, 0, Width, Height));
        if (history.Selected is { } selected && selected.IsVisible(Position))
        {
            var bounds = Bounds(selected.Annotation); double scale = Math.Max(0.05, ViewScale);
            bounds.Inflate(4 / scale, 4 / scale);
            dc.DrawRectangle(null, new Pen(Brushes.White, 1 / scale) { DashStyle = DashStyles.Dash }, bounds);
        }
    }
    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonDown(e); PauseRequested?.Invoke(); Focus();
        var mouse = e.GetPosition(this); var point = new PointD(mouse.X, mouse.Y).Clamp(new(0, 0, Width, Height));
        if (ActiveTool is not { } tool)
        {
            var selected = history.Items.LastOrDefault(item => item.IsVisible(Position) && Bounds(item.Annotation).Contains(mouse));
            SelectionRequested?.Invoke(selected?.Id); e.Handled = true; return;
        }
        if (tool == Tool.Text) { TextRequested?.Invoke(point); e.Handled = true; return; }
        anchor = point; points.Clear(); points.Add(point); live = Make(point); CaptureMouse(); Refresh(); e.Handled = true;
    }
    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (live == null || !IsMouseCaptured || live.Tool == Tool.Step) return;
        var mouse = e.GetPosition(this); var point = new PointD(mouse.X, mouse.Y).Clamp(new(0, 0, Width, Height));
        points.Add(point); live = Make(point); Refresh();
    }
    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonUp(e);
        if (live == null) return;
        var annotation = live; live = null; ReleaseMouseCapture();
        if (!annotation.IsRasterEffect || RasterEffects.Region(annotation, new(0, 0, Width, Height)) != null)
            AnnotationCreated?.Invoke(annotation);
        Refresh(); e.Handled = true;
    }
    protected override void OnLostMouseCapture(MouseEventArgs e)
    {
        base.OnLostMouseCapture(e);
        // Interruption (e.g. opening Save while dragging) never commits half a mark.
        if (live != null) { live = null; Refresh(); }
    }
    internal void CancelGesture() { live = null; if (IsMouseCaptured) ReleaseMouseCapture(); Refresh(); }
    private Annotation Make(PointD end)
    {
        var tool = ActiveTool!.Value;
        if ((Keyboard.Modifiers & ModifierKeys.Shift) != 0 && tool is Tool.Line or Tool.Arrow or Tool.Rectangle)
            end = SelectionGeometry.AxisLocked(anchor, end).Clamp(new(0, 0, Width, Height));
        double scale = Math.Max(0.05, ViewScale);
        return new(tool, tool is Tool.Pen or Tool.Marker ? points.ToArray() : tool == Tool.Step ? [anchor] : [anchor, end],
            settings.AnnotationColor, settings.LineWidth / scale, settings.FontSize / scale,
            StepNumber: Annotation.NextStepNumber(history.Items.Select(item => item.Annotation)));
    }
    private static Rect Bounds(Annotation annotation)
    {
        if (annotation.Points.Length == 0) return Rect.Empty;
        var points = annotation.Points;
        if (annotation.Tool == Tool.Text)
        {
            var text = AnnotationRenderer.Text(annotation.Text, annotation.FontSize, Brushes.White);
            return new(points[0].X, points[0].Y, Math.Max(1, text.Width), Math.Max(1, text.Height));
        }
        if (annotation.Tool == Tool.Step)
        {
            double radius = annotation.StepDiameter / 2;
            return new(points[0].X - radius, points[0].Y - radius, radius * 2, radius * 2);
        }
        double left = points.Min(p => p.X), top = points.Min(p => p.Y), right = points.Max(p => p.X), bottom = points.Max(p => p.Y);
        var bounds = new Rect(left, top, Math.Max(1, right - left), Math.Max(1, bottom - top));
        if (!annotation.IsRasterEffect) bounds.Inflate(Math.Max(8, annotation.EffectiveWidth), Math.Max(8, annotation.EffectiveWidth));
        return bounds;
    }
}
