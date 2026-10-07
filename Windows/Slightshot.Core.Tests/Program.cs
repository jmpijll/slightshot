using Slightshot.Core;

int checks = 0;
void Equal<T>(T expected, T actual, string message)
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new InvalidOperationException($"{message}: expected {expected}, got {actual}");
    checks++;
}
void Near(double expected, double actual, string message)
{
    if (Math.Abs(expected - actual) > 0.001) throw new InvalidOperationException($"{message}: expected {expected}, got {actual}"); checks++;
}

var bounds = new RectD(0, 0, 800, 600);
Equal(new RectD(10, 20, 80, 40), RectD.Between(new(90, 60), new(10, 20)), "reverse drag normalizes");
Equal(new RectD(0, 0, 800, 600), new RectD(-100, -100, 1000, 800).Clamp(bounds), "selection remains within monitor");
Equal(new RectD(0, 400, 200, 200), new RectD(20, 20, 200, 200).MoveTo(new(-20, 700), bounds), "move clamps both axes");
Equal(new RectD(100, 100, 80, 80), SelectionGeometry.Square(new(100, 100), new(120, 180), bounds), "Shift creates square");
// The previous opposite corner is 80,80, so dragging top-left past it yields 80,80…150,150.
Equal(new RectD(80, 80, 70, 70), SelectionHandle.TopLeft.Resize(new(50, 50, 30, 30), new(150, 150)), "resize normalizes after crossing");
Equal<SelectionHandle?>(SelectionHandle.TopLeft, SelectionGeometry.Hit(new(4, 4), new(0, 0, 8, 8)), "corners win overlapping handles");
var locked = SelectionGeometry.AxisLocked(new(0, 0), new(100, 85)); Near(locked.X, locked.Y, "Shift nearest 45 degrees");

var regular = OverlayStyle.Layout(new(100, 100, 200, 200), bounds);
Equal(new RectD(308, 100, 38, 265), regular.Tools, "Mac tool bar dimensions and right placement");
Equal(new RectD(163, 308, 137, 38), regular.Actions, "Mac actions below right aligned");
var edge = OverlayStyle.Layout(new(700, 500, 100, 100), bounds);
Equal(new RectD(654, 331, 38, 265), edge.Tools, "right edge flips tools to left and clamps vertically");
Equal(new RectD(659, 454, 137, 38), edge.Actions, "bottom edge flips actions above and clamps horizontally");
var full = OverlayStyle.Layout(bounds, bounds);
Equal(new RectD(754, 4, 38, 265), full.Tools, "full monitor tucks tools inside");
Equal(new RectD(659, 554, 137, 38), full.Actions, "full monitor tucks actions inside");
Equal(12, OverlayStyle.Swatches.Length, "same twelve Mac swatches");
Equal("#FF3B30", OverlayStyle.Swatches[0], "Mac default red");
Equal(new RectD(12, 25, 26, 38), new RectD(10, 20, 20, 30).ToPixels(1.25, 1.25, 100, 100), "fractional DPI covers selected pixels");
Equal(new RectD(99, 99, 1, 1), new RectD(100, 100, 0, 0).ToPixels(1, 1, 100, 100), "edge pixel crop is valid");

var when = new DateTimeOffset(2026, 10, 7, 14, 30, 5, TimeSpan.FromHours(2));
Equal("Screenshot 2026-10-07 at 14.30.05", OutputNaming.FileName("", when, 1200, 800), "default filename");
Equal("1200×800-2026-10-07", OutputNaming.FileName("{width}×{height}-{date}", when, 1200, 800), "filename tokens");
Equal("_CON", OutputNaming.FileName("CON", when, 1, 1), "reserved Windows filename");
Equal("_lpt9.png", OutputNaming.FileName("lpt9.png", when, 1, 1), "reserved stem with extension");
Equal("foo-bar-ba-", OutputNaming.FileName("foo/bar:ba?", when, 1, 1), "invalid Windows characters");
Equal("Screenshot", OutputNaming.FileName("...", when, 1, 1), "all dots fallback");
Equal(180, OutputNaming.FileName(new string('a', 300), when, 1, 1).Length, "long filename bounded");
Equal(18.0, new Annotation(Tool.Marker, [], "#FF3B30", 3).EffectiveWidth, "marker six times stroke width");
Near(0.35, new Annotation(Tool.Marker, [], "#FF3B30", 3).Alpha, "Mac marker opacity");
Console.WriteLine($"Passed {checks} Windows parity geometry, pixel-boundary, style and filename checks.");
