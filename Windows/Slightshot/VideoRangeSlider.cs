using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Shapes;

namespace Slightshot;

// A single visible interval with two native focusable Thumb handles. Pointer
// gestures and keyboard adjustments share the same clamped time calculation.
internal sealed class VideoRangeSlider : Grid
{
    private const double Inset = 7;
    private readonly Canvas canvas = new();
    private readonly Rectangle track = new() { Height = 5, RadiusX = 2.5, RadiusY = 2.5, Fill = AnnotationRenderer.Brush("#66666C") };
    private readonly Rectangle interval = new() { Height = 6, RadiusX = 3, RadiusY = 3, Fill = AnnotationRenderer.Brush("#FF3B30") };
    private readonly Thumb from, until;
    private readonly double duration, minimum;
    internal double Begin { get; private set; }
    internal double End { get; private set; }
    internal event Action? EditBeginning;
    internal event Action<double, double>? RangeChanged;
    internal event Action? EditCompleted;
    internal VideoRangeSlider(TimeSpan duration, TimeSpan minimum)
    {
        this.duration = duration.TotalSeconds; this.minimum = minimum.TotalSeconds; End = this.duration;
        Height = 34; MinWidth = 120; Margin = new Thickness(0, 6, 0, 8);
        from = Handle("Annotation start handle"); until = Handle("Annotation end handle");
        canvas.Children.Add(track); canvas.Children.Add(interval); canvas.Children.Add(from); canvas.Children.Add(until); Children.Add(canvas);
        from.DragStarted += (_, _) => EditBeginning?.Invoke(); until.DragStarted += (_, _) => EditBeginning?.Invoke();
        from.DragDelta += (_, e) => Move(true, Begin + e.HorizontalChange / TrackWidth * this.duration);
        until.DragDelta += (_, e) => Move(false, End + e.HorizontalChange / TrackWidth * this.duration);
        from.DragCompleted += (_, _) => EditCompleted?.Invoke(); until.DragCompleted += (_, _) => EditCompleted?.Invoke();
        from.PreviewKeyDown += (_, e) => HandleKey(true, e); until.PreviewKeyDown += (_, e) => HandleKey(false, e);
        SizeChanged += (_, _) => Layout(); SetRange(0, this.duration);
    }
    internal void SetRange(double begin, double end)
    {
        Begin = Math.Clamp(begin, 0, duration - minimum); End = Math.Clamp(end, Begin + minimum, duration);
        Layout();
    }
    internal Point HandleCenter(bool start) => new(Inset + (start ? Begin : End) / duration * TrackWidth, 17);
    internal Point PositionAt(double seconds) => new(Inset + Math.Clamp(seconds / duration, 0, 1) * TrackWidth, 17);
    private double TrackWidth => Math.Max(1, ActualWidth - Inset * 2);
    private void Move(bool start, double seconds)
    {
        double snapped = Math.Round(seconds * 30) / 30;
        if (start) Begin = Math.Clamp(snapped, 0, End - minimum);
        else End = Math.Clamp(snapped, Begin + minimum, duration);
        Layout(); RangeChanged?.Invoke(Begin, End);
    }
    private void Layout()
    {
        double left = Inset + Begin / duration * TrackWidth, right = Inset + End / duration * TrackWidth;
        track.Width = TrackWidth; Canvas.SetLeft(track, Inset); Canvas.SetTop(track, 14.5);
        interval.Width = Math.Max(1, right - left); Canvas.SetLeft(interval, left); Canvas.SetTop(interval, 14);
        Canvas.SetLeft(from, left - 5); Canvas.SetTop(from, 5);
        Canvas.SetLeft(until, right - 5); Canvas.SetTop(until, 5);
        from.ToolTip = $"From {Begin:0.00} seconds"; until.ToolTip = $"Until {End:0.00} seconds";
    }
    private void HandleKey(bool start, KeyEventArgs e)
    {
        double amount = (Keyboard.Modifiers & ModifierKeys.Shift) != 0 ? 10.0 / 30 : 1.0 / 30;
        double current = start ? Begin : End;
        double? next = e.Key switch { Key.Left or Key.Down => current - amount, Key.Right or Key.Up => current + amount, Key.Home => 0, Key.End => duration, _ => null };
        if (next == null) return;
        EditBeginning?.Invoke(); Move(start, next.Value); EditCompleted?.Invoke(); e.Handled = true;
    }
    private static Thumb Handle(string label)
    {
        var thumb = new Thumb { Width = 10, Height = 24, Focusable = true, Cursor = Cursors.SizeWE };
        thumb.Template = (ControlTemplate)XamlReader.Parse("<ControlTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' TargetType='Thumb'><Border CornerRadius='3' Background='White' BorderBrush='#FF3B30' BorderThickness='1.5'><Border Margin='3,5' Width='1' Background='#FF3B30'/></Border></ControlTemplate>");
        AutomationProperties.SetName(thumb, label); return thumb;
    }
}
