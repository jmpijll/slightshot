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
    private readonly CapturedDisplay? display;
    private readonly EditorImageSource imageSource;
    private readonly Canvas toolbarChrome;
    private readonly ScrollViewer? scroll;
    private readonly Grid imageContent;
    private double zoom = 1;
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
    private RectD Bounds => imageSource.Bounds;

    public OverlayWindow(CapturedDisplay display, Settings settings, bool underPointer, Action<OverlayWindow> takeOver, Action cancel, Action<OverlayWindow, CaptureAction, BitmapSource> complete, Action<CapturedDisplay, RectD>? record = null)
        : this(display.Source, settings, underPointer, takeOver, cancel, complete, display, record) { }

    public OverlayWindow(EditorImageSource imageSource, Settings settings, Action<OverlayWindow> takeOver, Action cancel, Action<OverlayWindow, CaptureAction, BitmapSource> complete)
        : this(imageSource, settings, false, takeOver, cancel, complete, null, null) { }

    private OverlayWindow(EditorImageSource imageSource, Settings settings, bool underPointer, Action<OverlayWindow> takeOver, Action cancel, Action<OverlayWindow, CaptureAction, BitmapSource> complete, CapturedDisplay? display, Action<CapturedDisplay, RectD>? record)
    {
        this.imageSource = imageSource; this.display = display; this.settings = settings; this.takeOver = takeOver; this.cancel = cancel; this.complete = complete;
        this.record = record ?? ((_, _) => { });
        Background = display == null ? Brushes.DimGray : Brushes.Black; Cursor = Cursors.Cross;
        surface = new OverlaySurface(imageSource, settings, display == null) { ShowHint = underPointer };
        RenderOptions.SetBitmapScalingMode(surface, BitmapScalingMode.NearestNeighbor);
        imageContent = new Grid(); imageContent.Children.Add(surface); imageContent.Children.Add(chrome);
        if (display != null)
        {
            WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize; ShowInTaskbar = false; Topmost = true;
            Width = display.Width; Height = display.Height; Left = display.Left / display.Scale; Top = display.Top / display.Scale;
            toolbarChrome = chrome; Content = imageContent;
            SourceInitialized += (_, _) => NativeMethods.SetWindowPos(new WindowInteropHelper(this).Handle, new IntPtr(-1), display.Left, display.Top, display.PixelWidth, display.PixelHeight, 0x0040);
        }
        else
        {
            Title = "Edit Image from Clipboard"; ResizeMode = ResizeMode.CanResize;
            Width = Math.Max(660, imageSource.Width + 36); Height = Math.Max(520, imageSource.Height + 90);
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            imageContent.Width = Math.Max(640, imageSource.Width); imageContent.Height = Math.Max(460, imageSource.Height);
            scroll = new ScrollViewer { Content = imageContent, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
            toolbarChrome = new Canvas();
            var editor = new Grid(); editor.Children.Add(scroll); editor.Children.Add(toolbarChrome);
            var controls = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(8, 4, 8, 4) };
            foreach (var (label, factor) in new[] { ("Fit", 1.0), ("100%", imageSource.Scale) })
            {
                var button = new Button { Content = label, Padding = new Thickness(10, 3, 10, 3), Margin = new Thickness(0, 0, 6, 0) };
                button.Click += (_, _) =>
                {
                    zoom = label == "Fit" ? Math.Min(1, Math.Min(scroll.ViewportWidth / imageSource.Width, scroll.ViewportHeight / imageSource.Height)) : factor;
                    imageContent.LayoutTransform = new ScaleTransform(zoom, zoom);
                    Refresh(); Focus();
                };
                controls.Children.Add(button);
            }
            var root = new DockPanel(); DockPanel.SetDock(controls, Dock.Top); root.Children.Add(controls); root.Children.Add(editor); Content = root;
            scroll.ScrollChanged += (_, _) => Refresh();
            SizeChanged += (_, _) => Refresh();
            surface.Selection = Bounds;
        }
        toolbar = new Toolbar(toolbarChrome, imageSource, settings, _ => { CommitText(); surface.MagnifierPoint = null; Refresh(); }, () => { Refresh(); }, Undo, Redo, Perform, cancel, BeginRecording, display != null);

        surface.MouseLeftButtonDown += MouseDownOnSurface; surface.MouseMove += MouseMoved; surface.MouseLeftButtonUp += MouseUpOnSurface;
        surface.MouseRightButtonDown += (_, _) => cancel();
        surface.MouseLeave += (_, _) => { surface.MagnifierPoint = null; surface.InvalidateVisual(); };
        PreviewKeyDown += KeyPressed;
        Loaded += (_, _) => Refresh();
    }

    public void Relinquish() { surface.ShowHint = false; surface.MagnifierPoint = null; surface.InvalidateVisual(); }
    private PointD Position(MouseEventArgs e) { var p = e.GetPosition(surface); return new PointD(p.X, p.Y).Clamp(Bounds); }
    private static bool Shift => Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
    private static bool Control => Keyboard.Modifiers.HasFlag(ModifierKeys.Control);
    private void MouseDownOnSurface(object sender, MouseButtonEventArgs e)
    {
        takeOver(this); surface.ShowHint = false; CommitText(); var p = Position(e);
        if (e.ClickCount == 2 && toolbar.ActiveTool != Tool.Step && surface.Selection is { } twice && twice.Contains(p)) { DefaultPerform(); return; }
        if (surface.Selection is { } selection)
        {
            if (SelectionGeometry.Hit(p, selection, zoom) is { } handle) { drag = Drag.ResizeSelection; resizeHandle = handle; resizeOriginal = selection; surface.CaptureMouse(); return; }
            if (toolbar.ActiveTool is { } tool && selection.Contains(p))
            {
                if (tool == Tool.Text) { BeginText(p); return; }
                drag = Drag.Drawing; anchor = p; points.Clear(); points.Add(p); surface.LiveAnnotation = MakeAnnotation(p); surface.CaptureMouse(); Refresh(); return;
            }
            if (selection.Contains(p)) { drag = Drag.MoveSelection; grabOffset = new(p.X - selection.Left, p.Y - selection.Top); surface.CaptureMouse(); return; }
        }
        StartSelection(p);
    }

    private void StartSelection(PointD point)
    {
        surface.Annotations.Clear(); surface.LiveAnnotation = null; copyOnRelease = Control; drag = Drag.NewSelection; anchor = point; surface.Selection = RectD.Between(point, point); surface.CaptureMouse(); Refresh();
    }

    private void SelectDisplay()
    {
        surface.ShowHint = false; surface.Selection = Bounds; surface.MagnifierPoint = null; surface.Annotations.DiscardRedo(); Refresh();
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
                if (surface.LiveAnnotation is { Tool: Tool.Step }) break;
                if (surface.Selection is { } drawing) { p = p.Clamp(drawing); points.Add(p); surface.LiveAnnotation = MakeAnnotation(p); }
                break;
        }
        surface.MagnifierPoint = surface.Selection == null || drag is Drag.NewSelection or Drag.ResizeSelection ? p : null;
        if (surface.Selection is { } selection)
        {
            Cursor = SelectionGeometry.Hit(p, selection, zoom) switch
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
            if (surface.Selection is { } r && (r.Width < (display == null ? 1 / imageSource.Scale : 4) || r.Height < (display == null ? 1 / imageSource.Scale : 4))) { surface.Selection = null; surface.ShowHint = true; }
            else if (copyOnRelease) { drag = Drag.None; copyOnRelease = false; Perform(CaptureAction.Copy); return; }
        }
        drag = Drag.None; copyOnRelease = false;
        if (surface.Selection != null) { surface.MagnifierPoint = null; toolbar.RestoreTool(); }
        Refresh();
    }

    private Annotation? MakeAnnotation(PointD end)
    {
        if (toolbar.ActiveTool is not { } tool) return null;
        if (tool == Tool.Step) return new(tool, [anchor], settings.AnnotationColor, settings.LineWidth, StepNumber: Annotation.NextStepNumber(surface.Annotations));
        // The Mac renderer applies the same 45° constraint to line, arrow and rectangle endpoints.
        if (Shift && tool is Tool.Line or Tool.Arrow or Tool.Rectangle) end = SelectionGeometry.AxisLocked(anchor, end);
        return new(tool, tool is Tool.Pen or Tool.Marker ? points.ToArray() : [anchor, end], settings.AnnotationColor, settings.LineWidth, settings.FontSize);
    }

    private void BeginText(PointD point)
    {
        textOrigin = new(point.X + 4, point.Y + 3);
        textEntry = new AnnotationTextBox { MinWidth = 64, MaxWidth = Math.Max(80, surface.Selection!.Value.Right - point.X), MinHeight = settings.FontSize * 1.6, FontFamily = new FontFamily("Segoe UI"), FontWeight = FontWeights.SemiBold, FontSize = settings.FontSize, Foreground = AnnotationRenderer.Brush(settings.AnnotationColor), CaretBrush = AnnotationRenderer.Brush(settings.AnnotationColor), Background = Brushes.Transparent, BorderThickness = new Thickness(0), Padding = new Thickness(4, 3, 4, 3), AcceptsReturn = true, TextWrapping = TextWrapping.Wrap };
        Canvas.SetLeft(textEntry, point.X); Canvas.SetTop(textEntry, point.Y); chrome.Children.Add(textEntry); textEntry.Focus();
        Refresh();
    }
    private void CommitText()
    {
        if (textEntry == null) return;
        string text = textEntry.Text; chrome.Children.Remove(textEntry); textEntry = null; Focus();
        if (!string.IsNullOrWhiteSpace(text)) surface.Annotations.Add(new(Tool.Text, [textOrigin], settings.AnnotationColor, settings.LineWidth, settings.FontSize, text));
        Refresh();
    }
    private void Undo()
    {
        if (textEntry != null) { chrome.Children.Remove(textEntry); textEntry = null; Focus(); Refresh(); return; }
        surface.Annotations.Undo();
        Refresh();
    }

    private void Redo()
    {
        if (textEntry != null || surface.LiveAnnotation != null) return;
        surface.Annotations.Redo();
        Refresh();
    }

    private bool HandleHistoryShortcut(Key key, ModifierKeys modifiers)
    {
        if (!modifiers.HasFlag(ModifierKeys.Control) || key is not (Key.Z or Key.Y)) return false;
        bool redo = key == Key.Y || modifiers.HasFlag(ModifierKeys.Shift);
        if (textEntry != null)
        {
            // WPF's text Undo remains native. Both redo gestures use that same
            // text history, including Ctrl+Shift+Z which WPF does not bind itself.
            if (!redo) return false;
            textEntry.Redo();
        }
        else if (redo) Redo();
        else Undo();
        return true;
    }

    private void KeyPressed(object sender, KeyEventArgs e)
    {
        Key key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key == Key.Escape) { if (textEntry != null) Undo(); else cancel(); e.Handled = true; return; }
        // Keep normal editing shortcuts inside the text field; export/save/print commit it first.
        if (textEntry != null && key == Key.Enter && Control) { CommitText(); e.Handled = true; return; }
        if (HandleHistoryShortcut(key, Keyboard.Modifiers)) { e.Handled = true; return; }
        if (Control)
        {
            switch (key)
            {
                case Key.A when textEntry == null: SelectDisplay(); break;
                case Key.C when textEntry == null: Perform(CaptureAction.Copy); break;
                case Key.S: Perform(Shift ? CaptureAction.SaveAs : CaptureAction.Save); break;
                case Key.P: Perform(CaptureAction.Print); break;
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
        if (display != null && surface.Selection is { Width: >= 8, Height: >= 8 } selection) record(display, selection);
    }
    private void Perform(CaptureAction action)
    {
        CommitText();
        if (surface.Selection is not { Width: > 0, Height: > 0 } selection) return;
        surface.MagnifierPoint = null;
        var bitmap = display == null ? AnnotationRenderer.Flatten(imageSource, selection, surface.Annotations)
            : AnnotationRenderer.Flatten(display, selection, surface.Annotations, settings.NativeResolution);
        complete(this, action, bitmap);
    }
    private void Refresh()
    {
        surface.InvalidateVisual();
        if (toolbar == null) return;
        toolbar.SetRedoAvailability(textEntry == null && surface.LiveAnnotation == null && surface.Annotations.CanRedo);
        var selection = surface.Selection;
        var bounds = Bounds;
        if (display == null)
        {
            bounds = new(0, 0, toolbarChrome.ActualWidth, toolbarChrome.ActualHeight);
            if (selection is { } r)
            {
                var origin = surface.TranslatePoint(new Point(r.X, r.Y), toolbarChrome);
                selection = new(origin.X, origin.Y, r.Width * zoom, r.Height * zoom);
            }
        }
        if (bounds.Width > 0 && bounds.Height > 0) toolbar.Layout(selection, bounds, drag != Drag.NewSelection);
    }


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
