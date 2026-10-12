using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Slightshot.Core;

namespace Slightshot;

// Pointer-centered editor chrome, outside the image/video annotation renderer.
internal sealed class AnnotationSizeIndicator : FrameworkElement
{
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1.2) };
    internal AnnotationSizeIndicator()
    {
        IsHitTestVisible = false; Visibility = Visibility.Collapsed;
        timer.Tick += (_, _) => Hide();
        Unloaded += (_, _) => timer.Stop();
    }
    protected override AutomationPeer OnCreateAutomationPeer() => new FrameworkElementAutomationPeer(this);
    protected override void OnRender(DrawingContext dc)
    {
        double radius = Math.Max(0, Math.Min(ActualWidth, ActualHeight) / 2 - 1);
        dc.DrawEllipse(AnnotationRenderer.Brush("#FF3B30", 0.14), new Pen(AnnotationRenderer.Brush("#FFFFFF", 0.95), 1.25),
            new Point(ActualWidth / 2, ActualHeight / 2), radius, radius);
    }
    internal void Show(AnnotationSizeChange change, Point point, Canvas host)
    {
        timer.Stop(); AutomationProperties.SetName(this, change.Label);
        if (Parent is not Canvas parent || parent != host)
        {
            (Parent as Canvas)?.Children.Remove(this); host.Children.Add(this);
        }
        Panel.SetZIndex(this, 100);
        Width = Height = change.IndicatorDiameter;
        Visibility = Visibility.Visible;
        Move(point, host); InvalidateVisual();
        timer.Start();
    }
    internal void Move(Point point, Canvas host)
    {
        if (Visibility != Visibility.Visible || Parent != host) return;
        Canvas.SetLeft(this, point.X - Width / 2); Canvas.SetTop(this, point.Y - Height / 2);
    }
    internal void Hide() { timer.Stop(); Visibility = Visibility.Collapsed; }
}
