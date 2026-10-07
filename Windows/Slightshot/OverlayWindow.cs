using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Slightshot.Core;

namespace Slightshot;

internal sealed class OverlayWindow : Window
{
    private readonly CapturedDisplay display;
    private readonly Settings settings;
    private readonly Action<OverlayWindow> takeOver;
    private readonly Action cancel;
    private readonly Action<OverlayWindow, CaptureAction, BitmapSource> complete;
    private readonly Action<CapturedDisplay, RectD> record;
    private readonly OverlaySurface surface;
    private readonly Canvas chrome = new();
    private readonly Toolbar toolbar;
    private TextBox? textEntry;
    private PointD textOrigin;
    private enum Drag { None, NewSelection, MoveSelection, ResizeSelection, Drawing }
    private Drag drag;
    private PointD anchor, grabOffset;
    private SelectionHandle resizeHandle;
    private RectD resizeOriginal;
    private readonly List<PointD> points = [];
    private bool copyOnRelease;
    private RectD Bounds => new(0, 0, display.Width, display.Height);

    public OverlayWindow(CapturedDisplay display, Settings settings, bool underPointer, Action<OverlayWindow> takeOver, Action cancel, Action<OverlayWindow, CaptureAction, BitmapSource> complete, Action<CapturedDisplay, RectD>? record = null)
    {
        this.display = display; this.settings = settings; this.takeOver = takeOver; this.cancel = cancel; this.complete = complete;
        this.record = record ?? ((_, _) => { });
        WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize; ShowInTaskbar = false; Topmost = true;
        Width = display.Width; Height = display.Height; Left = display.Left / display.Scale; Top = display.Top / display.Scale;
        Background = Brushes.Black; Cursor = Cursors.Cross;
        surface = new OverlaySurface(display, settings) { ShowHint = underPointer };
        RenderOptions.SetBitmapScalingMode(surface, BitmapScalingMode.NearestNeighbor);
        var grid = new Grid(); grid.Children.Add(surface); grid.Children.Add(chrome); Content = grid;
        toolbar = new Toolbar(chrome, display, settings, _ => { CommitText(); surface.MagnifierPoint = null; Refresh(); }, () => { Refresh(); }, Undo, Perform, cancel, BeginRecording);
        surface.MouseLeftButtonDown += MouseDownOnSurface; surface.MouseMove += MouseMoved; surface.MouseLeftButtonUp += MouseUpOnSurface;
        surface.MouseRightButtonDown += (_, _) => cancel();
        surface.MouseLeave += (_, _) => { surface.MagnifierPoint = null; surface.InvalidateVisual(); };
        PreviewKeyDown += KeyPressed;
        SourceInitialized += (_, _) =>
        {
            var handle = new WindowInteropHelper(this).Handle;
            NativeMethods.SetWindowPos(handle, new IntPtr(-1), display.Left, display.Top, display.PixelWidth, display.PixelHeight, 0x0040);
        };
    }

    public void Relinquish() { surface.ShowHint = false; surface.MagnifierPoint = null; surface.InvalidateVisual(); }
    private PointD Position(MouseEventArgs e) { var p = e.GetPosition(surface); return new PointD(p.X, p.Y).Clamp(Bounds); }
    private static bool Shift => Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
    private static bool Control => Keyboard.Modifiers.HasFlag(ModifierKeys.Control);
    private void MouseDownOnSurface(object sender, MouseButtonEventArgs e)
    {
        takeOver(this); surface.ShowHint = false; CommitText(); var p = Position(e);
        if (e.ClickCount == 2 && surface.Selection is { } twice && twice.Contains(p)) { DefaultPerform(); return; }
        if (surface.Selection is { } selection)
        {
            if (SelectionGeometry.Hit(p, selection) is { } handle) { drag = Drag.ResizeSelection; resizeHandle = handle; resizeOriginal = selection; surface.CaptureMouse(); return; }
            if (toolbar.ActiveTool is { } tool && selection.Contains(p))
            {
                if (tool == Tool.Text) { BeginText(p); return; }
                drag = Drag.Drawing; anchor = p; points.Clear(); points.Add(p); surface.LiveAnnotation = MakeAnnotation(p); surface.CaptureMouse(); return;
            }
            if (selection.Contains(p)) { drag = Drag.MoveSelection; grabOffset = new(p.X - selection.Left, p.Y - selection.Top); surface.CaptureMouse(); return; }
        }
        surface.Annotations.Clear(); surface.LiveAnnotation = null; copyOnRelease = Control; drag = Drag.NewSelection; anchor = p; surface.Selection = RectD.Between(p, p); surface.CaptureMouse(); Refresh();
    }

    private void MouseMoved(object sender, MouseEventArgs e)
    {
        var p = Position(e);
        switch (drag)
        {
            case Drag.NewSelection: surface.Selection = Shift ? SelectionGeometry.Square(anchor, p, Bounds) : RectD.Between(anchor, p); break;
            case Drag.MoveSelection:
                if (surface.Selection is { } moving) surface.Selection = moving.MoveTo(new(p.X - grabOffset.X, p.Y - grabOffset.Y), Bounds);
                break;
            case Drag.ResizeSelection: surface.Selection = resizeHandle.Resize(resizeOriginal, p).Clamp(Bounds); break;
            case Drag.Drawing:
                if (surface.Selection is { } drawing) { p = p.Clamp(drawing); points.Add(p); surface.LiveAnnotation = MakeAnnotation(p); }
                break;
        }
        surface.MagnifierPoint = surface.Selection == null || drag is Drag.NewSelection or Drag.ResizeSelection ? p : null;
        if (surface.Selection is { } selection)
        {
            Cursor = SelectionGeometry.Hit(p, selection) switch
            {
                SelectionHandle.Left or SelectionHandle.Right => Cursors.SizeWE,
                SelectionHandle.Top or SelectionHandle.Bottom => Cursors.SizeNS,
                SelectionHandle.TopLeft or SelectionHandle.BottomRight => Cursors.SizeNWSE,
                SelectionHandle.TopRight or SelectionHandle.BottomLeft => Cursors.SizeNESW,
                _ => toolbar.ActiveTool == null && selection.Contains(p) ? Cursors.Hand : Cursors.Cross
            };
        }
        else Cursor = Cursors.Cross;
        Refresh();
    }

    private void MouseUpOnSurface(object sender, MouseButtonEventArgs e)
    {
        surface.ReleaseMouseCapture();
        if (drag == Drag.Drawing && surface.LiveAnnotation is { } live)
        {
            if (!live.IsRasterEffect || surface.Selection is { } selection && RasterEffects.Region(live, selection) != null) surface.Annotations.Add(live);
            surface.LiveAnnotation = null;
        }
        if (drag == Drag.NewSelection)
        {
            if (surface.Selection is { } r && (r.Width < 4 || r.Height < 4)) { surface.Selection = null; surface.ShowHint = true; }
            else if (copyOnRelease) { drag = Drag.None; copyOnRelease = false; Perform(CaptureAction.Copy); return; }
        }
        drag = Drag.None; copyOnRelease = false;
        if (surface.Selection != null) { surface.MagnifierPoint = null; toolbar.RestoreTool(); }
        Refresh();
    }

    private Annotation? MakeAnnotation(PointD end)
    {
        if (toolbar.ActiveTool is not { } tool) return null;
        // The Mac renderer applies the same 45° constraint to line, arrow and rectangle endpoints.
        if (Shift && tool is Tool.Line or Tool.Arrow or Tool.Rectangle) end = SelectionGeometry.AxisLocked(anchor, end);
        return new(tool, tool is Tool.Pen or Tool.Marker ? points.ToArray() : [anchor, end], settings.AnnotationColor, settings.LineWidth, settings.FontSize);
    }

    private void BeginText(PointD point)
    {
        textOrigin = new(point.X + 4, point.Y + 3);
        textEntry = new AnnotationTextBox { MinWidth = 64, MaxWidth = Math.Max(80, surface.Selection!.Value.Right - point.X), MinHeight = settings.FontSize * 1.6, FontFamily = new FontFamily("Segoe UI"), FontWeight = FontWeights.SemiBold, FontSize = settings.FontSize, Foreground = AnnotationRenderer.Brush(settings.AnnotationColor), CaretBrush = AnnotationRenderer.Brush(settings.AnnotationColor), Background = Brushes.Transparent, BorderThickness = new Thickness(0), Padding = new Thickness(4, 3, 4, 3), AcceptsReturn = true, TextWrapping = TextWrapping.Wrap };
        Canvas.SetLeft(textEntry, point.X); Canvas.SetTop(textEntry, point.Y); chrome.Children.Add(textEntry); textEntry.Focus();
    }
    private void CommitText()
    {
        if (textEntry == null) return;
        string text = textEntry.Text; chrome.Children.Remove(textEntry); textEntry = null; Focus();
        if (!string.IsNullOrWhiteSpace(text)) surface.Annotations.Add(new(Tool.Text, [textOrigin], settings.AnnotationColor, settings.LineWidth, settings.FontSize, text));
        surface.InvalidateVisual();
    }
    private void Undo()
    {
        if (textEntry != null) { chrome.Children.Remove(textEntry); textEntry = null; Focus(); return; }
        if (surface.Annotations.Count > 0) surface.Annotations.RemoveAt(surface.Annotations.Count - 1);
        Refresh();
    }

    private void KeyPressed(object sender, KeyEventArgs e)
    {
        Key key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key == Key.Escape) { if (textEntry != null) Undo(); else cancel(); e.Handled = true; return; }
        // Keep normal editing shortcuts inside the text field; export/save/print commit it first.
        if (textEntry != null && key == Key.Enter && Control) { CommitText(); e.Handled = true; return; }
        if (Control)
        {
            switch (key)
            {
                case Key.A when textEntry == null: surface.ShowHint = false; surface.Selection = Bounds; surface.MagnifierPoint = null; Refresh(); break;
                case Key.C when textEntry == null: Perform(CaptureAction.Copy); break;
                case Key.S: Perform(Shift ? CaptureAction.SaveAs : CaptureAction.Save); break;
                case Key.P: Perform(CaptureAction.Print); break;
                case Key.Z when textEntry == null: Undo(); break;
                case Key.X when textEntry == null: cancel(); break;
                default: return;
            }
            e.Handled = true; return;
        }
        if (textEntry != null) return;
        if (key == Key.Enter) { DefaultPerform(); e.Handled = true; return; }
        int delta = Shift ? 10 : 1;
        PointD offset = key switch { Key.Left => new(-delta, 0), Key.Right => new(delta, 0), Key.Up => new(0, -delta), Key.Down => new(0, delta), _ => default };
        if (offset != default && surface.Selection is { } r) { surface.Selection = r.MoveTo(new(r.X + offset.X, r.Y + offset.Y), Bounds); Refresh(); e.Handled = true; }
    }
    private void DefaultPerform() { if (settings.DefaultAction != DefaultAction.StayOpen) Perform(settings.DefaultAction == DefaultAction.Save ? CaptureAction.Save : CaptureAction.Copy); }
    private void BeginRecording()
    {
        if (surface.Selection is { Width: >= 8, Height: >= 8 } selection) record(display, selection);
    }
    private void Perform(CaptureAction action)
    {
        CommitText();
        if (surface.Selection is not { Width: >= 1, Height: >= 1 } selection) return;
        surface.MagnifierPoint = null;
        complete(this, action, AnnotationRenderer.Flatten(display, selection, surface.Annotations, settings.NativeResolution));
    }
    private void Refresh() { surface.InvalidateVisual(); toolbar.Layout(surface.Selection, Bounds, drag != Drag.NewSelection); }

    internal void PrepareSmokeFixture(RectD selection, IEnumerable<Annotation> annotations)
    {
        surface.Selection = selection; surface.Annotations.AddRange(annotations); surface.ShowHint = false; toolbar.Select(Tool.Arrow); Refresh();
    }

    private sealed class AnnotationTextBox : TextBox
    {
        protected override void OnRender(DrawingContext dc)
        {
            base.OnRender(dc);
            var pen = new Pen(AnnotationRenderer.Brush("#FFFFFF", 0.7), 1) { DashStyle = new DashStyle([3.0, 3.0], 0) };
            dc.DrawRectangle(null, pen, new Rect(0.5, 0.5, Math.Max(0, ActualWidth - 1), Math.Max(0, ActualHeight - 1)));
        }
    }
}
