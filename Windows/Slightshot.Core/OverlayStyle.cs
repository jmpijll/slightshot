namespace Slightshot.Core;

// Keep these tokens aligned with ToolbarPanel, ToolbarController and PalettePanel on macOS.
public static class OverlayStyle
{
    public const double ButtonSize = 30;
    public const double ButtonRadius = 6;
    public const double PanelRadius = 9;
    public const double PanelPadding = 4;
    public const double ButtonSpacing = 2;
    public const double SelectionGap = 8;
    public const double DisplayMargin = 4;
    public const double ToolsWidth = 38;
    public const double ToolsHeight = 265; // 8 buttons + one 1-point separator + eight 2-point gaps + padding.
    public const double ActionsWidth = 169; // 5 buttons + separator + gaps + padding.
    public const double ActionsHeight = 38;
    public static readonly string[] Swatches = ["#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#00C7BE", "#0A84FF", "#5E5CE6", "#FF2D55", "#FFFFFF", "#8E8E93", "#000000", "#A2845E"];

    public static (RectD Tools, RectD Actions) Layout(RectD selection, RectD bounds)
    {
        double toolX = selection.Right + SelectionGap;
        if (toolX + ToolsWidth > bounds.Right - DisplayMargin) toolX = selection.Left - SelectionGap - ToolsWidth;
        if (toolX < DisplayMargin) toolX = Math.Max(DisplayMargin, selection.Right - ToolsWidth - SelectionGap);
        double toolY = Fit(selection.Top, ToolsHeight, bounds.Height);
        double actionY = selection.Bottom + SelectionGap;
        if (actionY + ActionsHeight > bounds.Bottom - DisplayMargin) actionY = selection.Top - SelectionGap - ActionsHeight;
        if (actionY < DisplayMargin) actionY = Math.Max(DisplayMargin, selection.Bottom - ActionsHeight - SelectionGap);
        return (new(toolX, toolY, ToolsWidth, ToolsHeight), new(Fit(selection.Right - ActionsWidth, ActionsWidth, bounds.Width), actionY, ActionsWidth, ActionsHeight));
    }

    public static double Fit(double value, double size, double available, double margin = DisplayMargin) => Math.Max(margin, Math.Min(value, available - size - margin));
}

public enum Tool { Pen, Line, Arrow, Rectangle, Marker, Text }
public enum CaptureAction { Copy, Save, SaveAs, Print }
public enum DefaultAction { Copy, Save, StayOpen }
public enum ImageFormat { Png, Jpeg, Tiff }

public sealed record Annotation(Tool Tool, PointD[] Points, string Color, double Width, double FontSize = 18, string Text = "")
{
    public double EffectiveWidth => Tool == Tool.Marker ? Width * 6 : Width;
    public double Alpha => Tool == Tool.Marker ? 0.35 : 1;
}
