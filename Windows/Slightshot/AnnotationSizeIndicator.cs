using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Slightshot.Core;

namespace Slightshot;

// Editor chrome stays outside the image/video annotation renderer.
internal sealed class AnnotationSizeIndicator : Border
{
    private readonly TextBlock label = new() { Foreground = Brushes.White, FontSize = 12, FontWeight = FontWeights.SemiBold };
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1.2) };
    internal AnnotationSizeIndicator()
    {
        Background = AnnotationRenderer.Brush("#17171A", 0.92);
        BorderBrush = AnnotationRenderer.Brush("#FFFFFF", 0.18); BorderThickness = new Thickness(1);
        CornerRadius = new CornerRadius(9); Padding = new Thickness(12, 8, 12, 8);
        Child = label; IsHitTestVisible = false; Visibility = Visibility.Collapsed;
        timer.Tick += (_, _) => Hide();
        Unloaded += (_, _) => timer.Stop();
    }
    internal void Show(AnnotationSizeChange change, Point point, Canvas host)
    {
        timer.Stop(); label.Text = change.Label; AutomationProperties.SetName(this, change.Label);
        if (Parent is not Canvas parent || parent != host)
        {
            (Parent as Canvas)?.Children.Remove(this); host.Children.Add(this);
        }
        Panel.SetZIndex(this, 100);
        Visibility = Visibility.Visible; Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        double x = point.X + 18, y = point.Y + 18;
        if (x + DesiredSize.Width > host.ActualWidth - 4) x = point.X - DesiredSize.Width - 18;
        if (y + DesiredSize.Height > host.ActualHeight - 4) y = point.Y - DesiredSize.Height - 18;
        Canvas.SetLeft(this, OverlayStyle.Fit(x, DesiredSize.Width, host.ActualWidth));
        Canvas.SetTop(this, OverlayStyle.Fit(y, DesiredSize.Height, host.ActualHeight));
        timer.Start();
    }
    internal void Hide() { timer.Stop(); Visibility = Visibility.Collapsed; }
}
