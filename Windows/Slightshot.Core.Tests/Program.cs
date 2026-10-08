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
Equal(new RectD(308, 100, 38, 329), regular.Tools, "tool bar fits the added rectangular effects on the right");
Equal(new RectD(131, 308, 169, 38), regular.Actions, "Mac actions with Record below right aligned");
var edge = OverlayStyle.Layout(new(700, 500, 100, 100), bounds);
Equal(new RectD(654, 267, 38, 329), edge.Tools, "right edge flips tools to left and clamps vertically");
Equal(new RectD(627, 454, 169, 38), edge.Actions, "bottom edge flips actions above and clamps horizontally");
var full = OverlayStyle.Layout(bounds, bounds);
Equal(new RectD(754, 4, 38, 329), full.Tools, "full monitor tucks tools inside");
Equal(new RectD(627, 554, 169, 38), full.Actions, "full monitor tucks actions inside");
Equal(12, OverlayStyle.Swatches.Length, "same twelve Mac swatches");
Equal("#FF3B30", OverlayStyle.Swatches[0], "Mac default red");
Equal(new RectD(12, 25, 26, 38), new RectD(10, 20, 20, 30).ToPixels(1.25, 1.25, 100, 100), "fractional DPI covers selected pixels");
Equal(new RectD(99, 99, 1, 1), new RectD(100, 100, 0, 0).ToPixels(1, 1, 100, 100), "edge pixel crop is valid");

var effect = new Annotation(Tool.Blur, [new(90, 60), new(10, 20)], "#FF3B30", 3);
Equal<RectD?>(new RectD(20, 30, 50, 30), RasterEffects.Region(effect, new(20, 30, 50, 50)), "reverse effect drag clips to screenshot selection");
Equal<RectD?>(null, RasterEffects.Region(effect, new(200, 200, 50, 50)), "effect outside selection is empty");
Equal<RectD?>(null, RasterEffects.Region(effect with { Points = [new(20, 20), new(20, 50)] }, bounds), "zero-width effect does not edit an edge pixel");
byte[] blocks = [0, 10, 20, 255, 20, 30, 40, 255, 200, 210, 220, 255, 40, 50, 60, 255, 60, 70, 80, 255, 100, 110, 120, 255];
RasterEffects.Pixelate(blocks, 3, 2, 2);
Equal(true, blocks.SequenceEqual(new byte[] {30, 40, 50, 255, 30, 40, 50, 255, 150, 160, 170, 255, 30, 40, 50, 255, 30, 40, 50, 255, 150, 160, 170, 255}), "pixelation averages real channels and partial edge blocks");
byte[] gradient = [0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255, 255];
RasterEffects.Blur(gradient, 3, 1, 1);
Equal(true, gradient.SequenceEqual(new byte[] {0, 0, 0, 255, 85, 85, 85, 255, 170, 170, 170, 255}), "blur mixes adjacent pixels and clamps screenshot edges");
var solid = Enumerable.Range(0, 49).SelectMany(_ => new byte[] {30, 80, 120, 255}).ToArray();
RasterEffects.Blur(solid, 7, 7, 8);
Equal(true, solid.Where((value, index) => value != new byte[] {30, 80, 120, 255}[index % 4]).Any() == false, "blur preserves a solid image at corners with a large radius");
var impulse = new byte[41 * 41 * 4];
for (int i = 3; i < impulse.Length; i += 4) impulse[i] = 255;
for (int c = 0; c < 3; c++) impulse[(20 * 41 + 20) * 4 + c] = 255;
RasterEffects.Blur(impulse, 41, 41, 2);
Equal(true, impulse[(20 * 41 + 20) * 4] is > 0 and < 255, "blur transforms the source instead of drawing an overlay");
Equal(true, impulse[(20 * 41 + 19) * 4] > 0, "blur spreads an impulse to nearby pixels");
Equal(impulse[(20 * 41 + 19) * 4], impulse[(20 * 41 + 21) * 4], "blur kernel is symmetric");
Equal(true, impulse[(19 * 41 + 20) * 4] > 0, "blur spreads an impulse vertically");
Equal(impulse[(19 * 41 + 20) * 4], impulse[(21 * 41 + 20) * 4], "vertical blur kernel is symmetric");

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
Equal((1280, 720), RecordingQuality.Compact.Dimensions(3840, 2160), "compact preserves aspect at 720p");
Equal((1920, 1080), RecordingQuality.Balanced.Dimensions(3840, 2160), "balanced preserves aspect at 1080p");
Equal((4096, 2304), RecordingQuality.High.Dimensions(7680, 4320), "high caps maximum encoder dimension");
Equal((320, 240), RecordingQuality.High.Dimensions(321, 241), "odd dimensions round inward");
Equal((720, 1280), RecordingQuality.Compact.Dimensions(2160, 3840), "portrait sizing");
Equal((2, 2), RecordingQuality.Compact.Dimensions(1, 1), "encoder minimum dimensions");
Equal(15, RecordingQuality.Compact.FramesPerSecond(), "compact frame rate");
Equal(24, RecordingQuality.Balanced.FramesPerSecond(), "balanced frame rate");
Equal(30, RecordingQuality.High.FramesPerSecond(), "high frame rate");
Equal(150000u, RecordingQuality.Compact.Bitrate(20, 20), "tiny video bitrate floor");
Equal(1105920u, RecordingQuality.Compact.Bitrate(1280, 720), "compact bitrate budget");
Equal("Small & fast", RecordingQuality.Compact.Title(), "Mac quality label");
foreach (var quality in Enum.GetValues<RecordingQuality>())
{
    var size = quality.Dimensions(3457, 1973);
    Equal(0, size.Width % 2, $"{quality} width even"); Equal(0, size.Height % 2, $"{quality} height even");
    Equal(true, Math.Max(size.Width, size.Height) <= quality.MaximumDimension(), $"{quality} dimension cap");
}
var dragPixels = Enumerable.Range(0, 400 * 200).SelectMany(_ => new byte[] {30, 80, 120, 255}).ToArray();
for (int iteration = 0; iteration < 10; iteration++) RasterEffects.Blur(dragPixels, 400, 200, 8);
long allocatedBefore = GC.GetAllocatedBytesForCurrentThread();
for (int iteration = 0; iteration < 20; iteration++) RasterEffects.Blur(dragPixels, 400, 200, 8);
long dragAllocations = GC.GetAllocatedBytesForCurrentThread() - allocatedBefore;
Console.WriteLine($"Warm 400×200 blur allocated {dragAllocations} bytes across 20 updates.");
Equal(true, dragAllocations < 32 * 1024, $"warm blur reuses full-frame scratch storage, allocated {dragAllocations} bytes");
var smallAfterLarge = Enumerable.Range(0, 15).SelectMany(_ => new byte[] {90, 100, 110, 255}).ToArray();
RasterEffects.Blur(smallAfterLarge, 3, 5, 8);
Equal(true, smallAfterLarge.SequenceEqual(Enumerable.Range(0, 15).SelectMany(_ => new byte[] {90, 100, 110, 255})), "pooled scratch cannot leak stale larger-image pixels into a smaller blur");
Console.WriteLine($"Passed {checks} Windows parity geometry, pixel-boundary, style and filename checks.");
