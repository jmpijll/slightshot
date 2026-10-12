using Slightshot.Core;

internal static class AnnotationSizeScrollChecks
{
    public static int Run()
    {
        int checks = 0;
        var scroll = new AnnotationSizeScroll();
        void Equal(double? expected, AnnotationSizeChange? actual)
        {
            if (expected != actual?.Value) throw new InvalidOperationException($"Scroll size: expected {expected}, got {actual?.Value}");
            checks++;
        }
        Equal(4, scroll.Adjust(Tool.Arrow, 3, 18, 1));
        Equal(2, scroll.Adjust(Tool.Pen, 3, 18, -1));
        Equal(12, scroll.Adjust(Tool.Marker, 12, 18, 100));
        Equal(1, scroll.Adjust(Tool.Line, 1, 18, -100));
        Equal(20, scroll.Adjust(Tool.Text, 3, 18, 1));
        Equal(48, scroll.Adjust(Tool.Text, 3, 48, 10));
        Equal(10, scroll.Adjust(Tool.Text, 3, 10, -10));
        foreach (var tool in new[] { Tool.Blur, Tool.Pixelate, Tool.Step }) Equal(null, scroll.Adjust(tool, 3, 18, 1));
        Equal(null, scroll.Adjust(Tool.Arrow, 3, 18, 0));
        Equal(null, scroll.Adjust(Tool.Arrow, 3, 18, 0.25));
        Equal(4, scroll.Adjust(Tool.Arrow, 3, 18, 0.75));
        Equal(null, scroll.Adjust(Tool.Arrow, 3, 18, 0.75));
        Equal(null, scroll.Adjust(Tool.Text, 3, 18, 0.25));
        foreach (var (text, value, diameter) in new[] { (false, 1.0, 18.0), (false, 12.0, 54.0),
            (true, 10.0, 18.0), (true, 48.0, 54.0), (false, -10.0, 18.0), (false, 100.0, 54.0), (false, double.NaN, 18.0) })
        {
            if (new AnnotationSizeChange(text, value).IndicatorDiameter != diameter) throw new InvalidOperationException("Halo size bounds");
            checks++;
        }
        if (new AnnotationSizeChange(false, 9).IndicatorDiameter >= new AnnotationSizeChange(false, 10).IndicatorDiameter)
            throw new InvalidOperationException("Halo grows as size increases");
        checks++;
        Equal(20, scroll.Adjust(Tool.Text, 3, 18, 0.75));
        scroll.Reset();
        Equal(null, scroll.Adjust(Tool.Text, 3, 18, 0.25));
        return checks;
    }
}
