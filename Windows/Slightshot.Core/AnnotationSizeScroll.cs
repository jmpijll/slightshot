namespace Slightshot.Core;

public sealed record AnnotationSizeChange(bool IsText, double Value)
{
    public string Label => $"{(IsText ? "Text size" : "Thickness")} {Math.Round(Value):0} pt";
}

public sealed class AnnotationSizeScroll
{
    private double remainder;
    private Tool? previousTool;
    public static bool Supports(Tool? tool) => tool is Tool.Pen or Tool.Line or Tool.Arrow or Tool.Rectangle or Tool.Marker or Tool.Text;
    public void Reset() { remainder = 0; previousTool = null; }
    // Delta is in wheel notches, including fractional high-resolution wheel input.
    public AnnotationSizeChange? Adjust(Tool tool, double width, double fontSize, double delta)
    {
        if (!Supports(tool) || !double.IsFinite(delta) || delta == 0) { Reset(); return null; }
        if (previousTool != tool) remainder = 0;
        previousTool = tool;
        remainder += Math.Clamp(delta, -100, 100);
        double steps = Math.Truncate(remainder);
        if (steps == 0) return null;
        remainder -= steps;
        bool isText = tool == Tool.Text;
        return new(isText, isText ? Math.Clamp(fontSize + steps * 2, 10, 48) : Math.Clamp(width + steps, 1, 12));
    }
}
