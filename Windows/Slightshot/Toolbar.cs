using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using Slightshot.Core;

namespace Slightshot;

internal sealed class ToolbarButton : Button
{
    private readonly ProductIcon? icon;
    public string Accent { get; set; } = "#FF3B30";
    public bool Selected { get; set; }
    public string? Swatch { get; set; }
    public ToolbarButton(ProductIcon? icon, string tooltip, Action onClick)
    {
        this.icon = icon;
        Width = Height = OverlayStyle.ButtonSize;
        ToolTip = tooltip; FocusVisualStyle = null; OverridesDefaultStyle = true;
        AutomationProperties.SetName(this, tooltip);
        Click += (_, _) => onClick();
        IsKeyboardFocusWithinChanged += (_, _) => InvalidateVisual();
        IsEnabledChanged += (_, _) => InvalidateVisual();
    }
    protected override void OnMouseEnter(MouseEventArgs e) { base.OnMouseEnter(e); InvalidateVisual(); }
    protected override void OnMouseLeave(MouseEventArgs e) { base.OnMouseLeave(e); InvalidateVisual(); }
    protected override void OnRender(DrawingContext dc)
        => DrawContent(dc, IsMouseOver);
    internal void DrawContent(DrawingContext dc, bool hovering)
    {
        dc.DrawRoundedRectangle(Selected ? AnnotationRenderer.Brush(Accent) : hovering ? AnnotationRenderer.Brush("#FFFFFF", 0.16) : Brushes.Transparent, IsKeyboardFocused ? new Pen(Brushes.White, 1) : null, new Rect(0, 0, 30, 30), 6, 6);
        if (Swatch != null) { dc.DrawEllipse(AnnotationRenderer.Brush(Swatch), new Pen(AnnotationRenderer.Brush("#FFFFFF", 0.7), 1.5), new Point(15, 15), 7, 7); return; }
        var brush = AnnotationRenderer.Brush("#FFFFFF", Selected || hovering ? 1 : 0.85);
        if (!IsEnabled) dc.PushOpacity(0.5);
        double inset = (OverlayStyle.ButtonSize - ProductIcons.Size) / 2;
        dc.PushTransform(new TranslateTransform(inset, inset));
        if (icon is { } glyph) ProductIcons.Draw(glyph, dc, brush);
        dc.Pop();
        if (!IsEnabled) dc.Pop();
    }
}

internal sealed class FrostedPanel : Grid
{
    private readonly Image backdrop = new() { Stretch = Stretch.Fill, IsHitTestVisible = false, Effect = new BlurEffect { Radius = 12 } };
    public FrostedPanel(UIElement content)
    {
        Children.Add(backdrop);
        Children.Add(new Border { Background = AnnotationRenderer.Brush("#17171A", 0.83), IsHitTestVisible = false });
        Children.Add(content);
        Children.Add(new Border { CornerRadius = new CornerRadius(9), BorderBrush = AnnotationRenderer.Brush("#FFFFFF", 0.18), BorderThickness = new Thickness(1), IsHitTestVisible = false });
        Effect = new DropShadowEffect { BlurRadius = 10, ShadowDepth = 2, Direction = 270, Color = Colors.Black, Opacity = 0.5 };
        SizeChanged += (_, _) => Clip = new RectangleGeometry(new Rect(RenderSize), 9, 9);
    }
    public void Place(RectD rect, CapturedDisplay display)
    {
        Canvas.SetLeft(this, rect.X); Canvas.SetTop(this, rect.Y); Width = rect.Width; Height = rect.Height;
        var pixelRect = rect.ToPixels(display.Scale, display.Scale, display.PixelWidth, display.PixelHeight);
        backdrop.Source = new CroppedBitmap(display.Image, new Int32Rect((int)pixelRect.X, (int)pixelRect.Y, (int)pixelRect.Width, (int)pixelRect.Height));
    }
}

internal sealed class Toolbar
{
    private readonly Canvas host;
    private readonly CapturedDisplay display;
    private readonly Settings settings;
    private readonly Action<Tool?> toolChanged;
    private readonly Action changed;
    private readonly Dictionary<Tool, ToolbarButton> buttons = [];
    private readonly ToolbarButton colorButton;
    private readonly FrostedPanel tools, actions;
    private FrostedPanel? palette;
    private RectD toolsRect;
    private readonly List<SwatchButton> swatches = [];
    private static Tool? lastTool;
    public Tool? ActiveTool { get; private set; }
    private static ProductIcon IconForTool(Tool tool) => tool switch
    {
        Tool.Pen => ProductIcon.Pen, Tool.Line => ProductIcon.Line,
        Tool.Arrow => ProductIcon.Arrow, Tool.Rectangle => ProductIcon.Rectangle,
        Tool.Marker => ProductIcon.Marker, Tool.Text => ProductIcon.Text,
        Tool.Blur => ProductIcon.Blur, Tool.Pixelate => ProductIcon.Pixelate,
        _ => throw new ArgumentOutOfRangeException(nameof(tool))
    };

    public Toolbar(Canvas host, CapturedDisplay display, Settings settings, Action<Tool?> toolChanged, Action changed, Action undo, Action<CaptureAction> perform, Action close, Action record)
    {
        this.host = host; this.display = display; this.settings = settings; this.toolChanged = toolChanged; this.changed = changed;
        var toolViews = new List<FrameworkElement>();
        foreach (var tool in Enum.GetValues<Tool>())
        {
            var button = new ToolbarButton(IconForTool(tool), tool.ToString(), () => Select(ActiveTool == tool ? null : tool)) { Accent = settings.AnnotationColor };
            buttons[tool] = button; toolViews.Add(button);
        }
        toolViews.Add(Separator(true));
        colorButton = new ToolbarButton(null, "Colour", TogglePalette) { Swatch = settings.AnnotationColor };
        toolViews.Add(colorButton); toolViews.Add(new ToolbarButton(ProductIcon.Undo, "Undo  Ctrl+Z", undo));
        tools = new FrostedPanel(Stack(toolViews, true));
        actions = new FrostedPanel(Stack([
            new ToolbarButton(ProductIcon.Print, "Print  Ctrl+P", () => perform(CaptureAction.Print)),
            new ToolbarButton(ProductIcon.Copy, "Copy  Ctrl+C", () => perform(CaptureAction.Copy)),
            new ToolbarButton(ProductIcon.Save, "Save  Ctrl+S  ·  Save As  Ctrl+Shift+S", () => perform(CaptureAction.Save)),
            new ToolbarButton(ProductIcon.Record, "Record selected area", record),
            Separator(false), new ToolbarButton(ProductIcon.Close, "Close  Esc", close)], false));
        host.Children.Add(tools); host.Children.Add(actions); SetVisible(false);
    }

    public void Select(Tool? tool)
    {
        ActiveTool = tool;
        foreach (var (candidate, button) in buttons) { button.Selected = candidate == tool; button.InvalidateVisual(); }
        colorButton.IsEnabled = tool is not (Tool.Blur or Tool.Pixelate);
        if (tool == null || !colorButton.IsEnabled) HidePalette();
        if (settings.RememberLastTool) lastTool = tool;
        toolChanged(tool);
    }
    public void RestoreTool() { if (settings.RememberLastTool && ActiveTool == null && lastTool != null) Select(lastTool); }
    public void Layout(RectD? selection, RectD bounds, bool visible)
    {
        visible = visible && selection is { Width: >= 8, Height: >= 8 };
        SetVisible(visible);
        if (!visible || selection == null) return;
        var layout = OverlayStyle.Layout(selection.Value, bounds); toolsRect = layout.Tools;
        tools.Place(layout.Tools, display); actions.Place(layout.Actions, display); LayoutPalette(bounds);
    }
    private void SetVisible(bool visible)
    {
        tools.Visibility = actions.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        if (palette != null) palette.Visibility = tools.Visibility;
    }
    public void HidePalette() { if (palette != null) host.Children.Remove(palette); palette = null; swatches.Clear(); }
    private void TogglePalette()
    {
        if (palette != null) { HidePalette(); return; }
        var column = new StackPanel { Margin = new Thickness(8) };
        for (int row = 0; row < 2; row++)
        {
            var line = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, row == 0 ? 4 : 8) };
            for (int index = 0; index < 6; index++)
            {
                string hex = OverlayStyle.Swatches[row * 6 + index];
                var swatch = new SwatchButton(hex, () => PickColor(hex)) { Picked = hex == settings.AnnotationColor, Margin = new Thickness(0, 0, index == 5 ? 0 : 4, 0) };
                swatches.Add(swatch); line.Children.Add(swatch);
            }
            column.Children.Add(line);
        }
        var slider = new Slider { Minimum = 1, Maximum = 12, Value = settings.LineWidth, Width = 140, Height = 18, ToolTip = "Thickness", IsMoveToPointEnabled = true };
        AutomationProperties.SetName(slider, "Thickness");
        slider.ValueChanged += (_, _) => { settings.LineWidth = slider.Value; changed(); };
        column.Children.Add(slider);
        palette = new FrostedPanel(column); host.Children.Add(palette); LayoutPalette(new(0, 0, display.Width, display.Height));
    }
    private void PickColor(string hex)
    {
        settings.AnnotationColor = hex; colorButton.Swatch = hex; colorButton.InvalidateVisual();
        foreach (var button in buttons.Values) { button.Accent = hex; button.InvalidateVisual(); }
        foreach (var button in swatches) { button.Picked = button.Hex == hex; button.InvalidateVisual(); }
        changed();
    }
    private void LayoutPalette(RectD bounds)
    {
        if (palette == null) return;
        const double width = 156, height = 86;
        double x = toolsRect.Right + 8;
        if (x + width > bounds.Right - 4) x = toolsRect.Left - 8 - width;
        // The colour button follows six tools and the separator in the vertical bar.
        double swatchY = toolsRect.Top + 4 + 6 * 32 + 3 + 15;
        palette.Place(new(OverlayStyle.Fit(x, width, bounds.Width), OverlayStyle.Fit(swatchY - height / 2, height, bounds.Height), width, height), display);
    }
    private static StackPanel Stack(IEnumerable<FrameworkElement> views, bool vertical)
    {
        var stack = new StackPanel { Orientation = vertical ? Orientation.Vertical : Orientation.Horizontal, Margin = new Thickness(4) };
        var array = views.ToArray();
        for (int i = 0; i < array.Length; i++)
        {
            array[i].Margin = vertical ? new Thickness(0, 0, 0, i == array.Length - 1 ? 0 : 2) : new Thickness(0, 0, i == array.Length - 1 ? 0 : 2, 0);
            stack.Children.Add(array[i]);
        }
        return stack;
    }
    private static FrameworkElement Separator(bool vertical) => new Border { Width = vertical ? 22 : 1, Height = vertical ? 1 : 22, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Background = AnnotationRenderer.Brush("#FFFFFF", 0.18) };

    private sealed class SwatchButton : Button
    {
        public string Hex { get; }
        public bool Picked { get; set; }
        public SwatchButton(string hex, Action click)
        {
            Hex = hex; Width = Height = 20; ToolTip = hex; OverridesDefaultStyle = true; FocusVisualStyle = null;
            AutomationProperties.SetName(this, hex); Click += (_, _) => click(); IsKeyboardFocusWithinChanged += (_, _) => InvalidateVisual();
        }
        protected override void OnRender(DrawingContext dc)
        {
            dc.DrawRectangle(Brushes.Transparent, null, new Rect(0, 0, 20, 20));
            dc.DrawEllipse(AnnotationRenderer.Brush(Hex), new Pen(AnnotationRenderer.Brush("#FFFFFF", 0.35), 1), new(10, 10), 8, 8);
            if (Picked || IsKeyboardFocused) dc.DrawEllipse(null, new Pen(Brushes.White, 1.5), new(10, 10), 9.25, 9.25);
        }
    }
}
