using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Slightshot.Core;

namespace Slightshot;

// Native HWNDs and actual pointer/slider/button interaction, using a synthetic
// moving video to avoid capturing personal desktop content in review evidence.
internal static class VideoEditorSmokeTest
{
    internal static async Task RunAsync(string directory)
    {
        directory = Path.GetFullPath(directory); Directory.CreateDirectory(directory);
        const int width = 640, height = 360;
        var checks = new List<string>(); int count = 0;
        for (int iteration = 0; iteration < 5; iteration++) { using var worker = new VideoRenderWorker(); }
        checks.Add("Five immediate compositor-worker startup/shutdown cycles complete without joining a live dispatcher, covering cancellation before its first frame.");
        using var session = new RecordingSession(width, height, pixels =>
        {
            int number = Interlocked.Increment(ref count);
            for (int y = 0; y < height; y++) for (int x = 0; x < width; x++)
            {
                int offset = (y * width + x) * 4;
                bool pattern = y is >= 175 and < 315 && x is >= 20 and < 280;
                byte shade = pattern ? ((x / 4 + y / 4) % 2 == 0 ? (byte)25 : (byte)230) : (byte)238;
                pixels[offset] = y < 12 ? (byte)(number % 200) : shade;
                pixels[offset + 1] = shade; pixels[offset + 2] = shade; pixels[offset + 3] = 255;
            }
        });
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        session.Started += () => started.TrySetResult();
        Task recording = session.RunAsync();
        await Task.WhenAny(started.Task, recording).WaitAsync(TimeSpan.FromSeconds(30));
        if (recording.IsCompleted) await recording;
        await started.Task.WaitAsync(TimeSpan.FromSeconds(30));
        await Task.Delay(4300); session.Stop(); await recording.WaitAsync(TimeSpan.FromSeconds(30));
        Require(count > 30, "synthetic source recorded actual moving frames");
        File.Copy(session.SourcePath, Path.Combine(directory, "video-editor-source.mp4"), true);
        var source = await VideoFrameSource.OpenAsync(session.SourcePath);
        int saveAttempts = 0;
        var editor = new VideoEditorWindow(source, new Settings { AnnotationColor = "#FF3B30", LineWidth = 5, FontSize = 24 }, _ => { saveAttempts++; return Task.FromResult(false); }, true);
        try
        {
            editor.Show(); editor.Activate(); await editor.InitializeAsync(); await Task.Delay(200); editor.UpdateLayout();
            Require(editor.IsVisible && editor.Surface.CurrentFrame is { PixelWidth: width, PixelHeight: height }, "native editor displays full-resolution source pixels");
            var top = new byte[4]; var bottom = new byte[4];
            editor.Surface.CurrentFrame!.CopyPixels(new Int32Rect(5, 5, 1, 1), top, 4, 0);
            editor.Surface.CurrentFrame.CopyPixels(new Int32Rect(5, height - 5, 1, 1), bottom, 4, 0);
            Require(bottom[0] - top[0] > 30, "native BGRA source keeps the moving stripe at the top (positive media stride)");
            foreach (var tool in Enum.GetValues<Tool>())
                Require(Buttons(editor).Any(button => Equals(button.ToolTip, tool == Tool.Step ? "Numbered steps" : tool.ToString())), "screenshot tool available: " + tool);
            var from = Descendants((DependencyObject)editor.Content).OfType<TextBox>().Single(field => AutomationProperties.GetName(field) == "Annotation start time in seconds");
            var until = Descendants((DependencyObject)editor.Content).OfType<TextBox>().Single(field => AutomationProperties.GetName(field) == "Annotation end time in seconds");
            var range = Descendants((DependencyObject)editor.Content).OfType<VideoRangeSlider>().Single();
            void ExactTiming()
            {
                from.Text = "1"; from.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(from)!, 0, Key.Enter) { RoutedEvent = Keyboard.PreviewKeyDownEvent });
                until.Text = "3"; until.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(until)!, 0, Key.Enter) { RoutedEvent = Keyboard.PreviewKeyDownEvent });
            }
            void Add(Annotation annotation)
            {
                editor.AddAnnotation(annotation);
                Require(editor.History.Selected!.Begin == TimeSpan.Zero && editor.History.Selected.End == source.Duration, "new mark defaults to the whole clip");
                ExactTiming();
            }
            Add(new(Tool.Blur, [new(28, 183), new(138, 305)], "#FF3B30", 5));
            Add(new(Tool.Pixelate, [new(158, 183), new(270, 305)], "#FF3B30", 5));
            Guid pixelate = editor.History.SelectedId!.Value;
            Add(new(Tool.Text, [new(305, 75)], "#0A84FF", 5, 34, "Only 1–3 seconds"));
            Add(new(Tool.Pen, [new(330, 320), new(390, 300), new(450, 320), new(530, 300)], "#34C759", 7));
            Add(new(Tool.Rectangle, [new(300, 135), new(590, 285)], "#FF9500", 4));
            Add(new(Tool.Marker, [new(330, 118), new(560, 118)], "#FFCC00", 3));
            Add(new(Tool.Step, [new(585, 40)], "#FF3B30", 3, StepNumber: 1));
            Add(new(Tool.Line, [new(330, 330), new(550, 330)], "#5E5CE6", 4));
            int fixtureMarks = editor.History.Items.Count;
            ClickTooltip(editor, "Arrow");
            await DragAsync(editor.Surface, new(350, 250), new(480, 175));
            Require(editor.History.Items.Count == fixtureMarks + 1 && editor.History.Selected!.Annotation.Tool == Tool.Arrow, "real native pointer drag creates an arrow through the production tool");
            var arrowPoints = editor.History.Selected!.Annotation.Points;
            Require(Math.Abs(arrowPoints[0].X - 350) < 3 && Math.Abs(arrowPoints[0].Y - 250) < 3 && Math.Abs(arrowPoints[^1].X - 480) < 3 && Math.Abs(arrowPoints[^1].Y - 175) < 3, "native Viewbox interaction maps pointer positions to source pixels");
            await DragAsync(range, range.HandleCenter(true), range.PositionAt(1));
            await DragAsync(range, range.HandleCenter(false), range.PositionAt(3));
            Require(Math.Abs(editor.History.Selected!.Begin.TotalSeconds - 1) < 0.08 && Math.Abs(editor.History.Selected.End.TotalSeconds - 3) < 0.08, "two native interval handles change the selected annotation period");
            editor.SetSelectedTiming(TimeSpan.Zero, source.Duration);
            ExactTiming();
            ClickTooltip(editor, "Undo  Ctrl+Z");
            Require(editor.History.Selected!.End == source.Duration, "real Undo reverses annotation timing");
            ClickTooltip(editor, "Redo  Ctrl+Y / Ctrl+Shift+Z");
            Require(editor.History.Selected!.End == TimeSpan.FromSeconds(3), "real Redo restores annotation timing");
            ClickContent(editor, "Delete annotation");
            Require(editor.History.Items.Count == fixtureMarks, "native delete removes selected mark");
            ClickTooltip(editor, "Undo  Ctrl+Z");
            Require(editor.History.Items.Count == fixtureMarks + 1, "Undo restores deleted mark");
            editor.SelectAnnotation(pixelate);
            checks.Add("Actual WPF tool icons, native pointer-drawn arrow, automated annotation fixtures for every tool, two native range handles and exact time fields, timing Undo/Redo and Delete/Undo passed. Marks cover 1–3 seconds at fixed source coordinates.");
            await editor.SeekAsync(TimeSpan.FromSeconds(0.5));
            TimeSpan position = editor.Position; editor.Play(); await Task.Delay(450); editor.Pause();
            Require(editor.Position > position, "Play advances the native preview");
            await editor.SeekAsync(TimeSpan.FromSeconds(0.5));
            var playhead = Sliders(editor).Single(slider => AutomationProperties.GetName(slider) == "Recording playhead");
            playhead.Value = 2; await editor.SeekAsync(TimeSpan.FromSeconds(2));
            Require(editor.Position == TimeSpan.FromSeconds(2), "native playhead scrubs to a chosen frame");
            checks.Add("Play/Pause advances moving source frames, and the accessible native playhead slider scrubs to the requested time.");
            var snapshot = editor.History.ExportSnapshot();
            var previews = new Dictionary<string, BitmapSource>();
            foreach (var point in new[] { (Name: "before", Seconds: 0.5), (Name: "during", Seconds: 2.0), (Name: "after", Seconds: 3.5) })
            {
                await editor.SeekAsync(TimeSpan.FromSeconds(point.Seconds));
                Require(editor.Surface.CurrentFrame != null, "preview decoded " + point.Name);
                var rendered = VideoAnnotationRenderer.Render(editor.Surface.CurrentFrame!, editor.Position, snapshot);
                previews.Add(point.Name, rendered);
                Save(rendered, Path.Combine(directory, "video-editor-preview-" + point.Name + ".png"));
                await Task.Delay(180); editor.UpdateLayout(); NativeMethods.DwmFlush();
                CaptureWindow(editor, Path.Combine(directory, "video-editor-" + point.Name + ".png"));
                if (point.Name == "during")
                {
                    double blurDelta = Delta(editor.Surface.CurrentFrame!, rendered, new Int32Rect(40, 195, 85, 95));
                    double pixelDelta = Delta(editor.Surface.CurrentFrame!, rendered, new Int32Rect(170, 195, 85, 95));
                    Require(blurDelta > 40, $"blur changes real preview pixels during its interval (mean delta {blurDelta:0.00})");
                    Require(pixelDelta > 40, $"pixelation changes real preview pixels during its interval (mean delta {pixelDelta:0.00})");
                }
                else Require(Delta(editor.Surface.CurrentFrame!, rendered, new Int32Rect(20, 70, 590, 250)) == 0, "annotations absent from preview " + point.Name + " their interval");
            }
            checks.Add("Focused composed-desktop screenshots capture the real editor before, during and after the interval. Pixel checks show Blur/Pixelate change the source only inside the interval; all annotations disappear outside it.");
            int marksBeforeCancel = editor.History.Items.Count;
            ClickContent(editor, "Save MP4…"); await Task.Delay(50);
            Require(saveAttempts == 1 && editor.IsVisible && editor.History.Items.Count == marksBeforeCancel && File.Exists(session.SourcePath), "cancelled Save returns to the same video and annotations");
            using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
            string preserved = Path.Combine(directory, "preserved.mp4"); byte[] original = [11, 22, 33, 44]; File.WriteAllBytes(preserved, original);
            byte[] retainedSource = System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(session.SourcePath));
            foreach (string alias in new[] { session.SourcePath, Path.Combine(Path.GetDirectoryName(session.SourcePath)!, ".", Path.GetFileName(session.SourcePath).ToUpperInvariant()) })
            {
                foreach (Func<Task> operation in new Func<Task>[]
                {
                    () => VideoAnnotationExport.SaveAsync(session.SourcePath, alias, RecordingQuality.High, width, height, snapshot, CancellationToken.None),
                    () => VideoAnnotationExport.SaveAsync(session.SourcePath, alias, RecordingQuality.High, width, height, [], CancellationToken.None),
                    () => RecordingExport.SaveAsync(session.SourcePath, alias, RecordingQuality.High, width, height, CancellationToken.None)
                })
                {
                    bool rejected = false;
                    try { await operation(); }
                    catch (InvalidOperationException error) when (error.Message.StartsWith("Choose a save location", StringComparison.Ordinal)) { rejected = true; }
                    Require(rejected, "same-source destination rejected before staging, including normalized case-insensitive aliases");
                }
            }
            Require(retainedSource.SequenceEqual(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(session.SourcePath))) && File.ReadAllBytes(preserved).SequenceEqual(original), "same-source rejection preserves original video and existing destination bytes");
            Require(!Directory.EnumerateFiles(session.DirectoryPath, ".slightshot-*").Any(), "same-source rejection creates no temporary staging file");
            checks.Add("Annotated, empty-annotation and plain recording exports reject exact and normalized/case-insensitive source-path destinations before staging; SHA-256 confirms the source is unchanged and existing destination bytes are retained.");
            await ExpectCancellation(() => VideoAnnotationExport.SaveAsync(session.SourcePath, preserved, RecordingQuality.High, width, height, snapshot, cancellation.Token));
            Require(File.ReadAllBytes(preserved).SequenceEqual(original), "early export cancellation preserves destination");
            using (var activeCancellation = new CancellationTokenSource())
            {
                var progress = new CancelOnProgress(activeCancellation);
                await ExpectCancellation(() => VideoAnnotationExport.SaveAsync(session.SourcePath, preserved, RecordingQuality.High, width, height, snapshot, activeCancellation.Token, progress));
                Require(progress.Called && File.ReadAllBytes(preserved).SequenceEqual(original), "active annotated export cancellation preserves destination");
            }
            Require(!Directory.EnumerateFiles(directory, ".slightshot-*").Any() && File.Exists(session.SourcePath), "cancellation cleans staging and retains source");
            try
            {
                await VideoAnnotationExport.SaveAsync(session.SourcePath, Path.Combine(directory, "missing", "edited.mp4"), RecordingQuality.High, width, height, snapshot, CancellationToken.None);
                throw new InvalidOperationException("Missing export folder did not fail.");
            }
            catch (Exception error) when (error is not InvalidOperationException) { }
            Require(editor.History.Items.Count == marksBeforeCancel && File.Exists(session.SourcePath), "failed export retains video and all edits");
            checks.Add("Save callback cancellation, early/active native export cancellation and a real failed destination preserve source, edits and an existing destination; cancelled staging files are removed.");
            File.Delete(preserved);
            foreach (var quality in Enum.GetValues<RecordingQuality>())
            {
                var sourceStripe = new List<double>(); var outputStripe = new List<double>();
                string output = Path.Combine(directory, "video-editor-" + quality.ToString().ToLowerInvariant() + ".mp4");
                var watch = Stopwatch.StartNew();
                await VideoAnnotationExport.SaveAsync(session.SourcePath, output, quality, width, height, snapshot, CancellationToken.None);
                using var decoded = await VideoFrameSource.OpenAsync(output);
                Require(decoded.Width == width && decoded.Height == height, "edited export retains dimensions " + quality);
                Require(Math.Abs(decoded.Duration.TotalSeconds - source.Duration.TotalSeconds) < 0.2, "edited export retains duration " + quality);
                var cadence = await VideoSequentialDecoder.InspectAsync(output, decoded.Width, decoded.Height);
                long expectedFrames = (source.Duration.Ticks * quality.FramesPerSecond() + TimeSpan.TicksPerSecond - 1) / TimeSpan.TicksPerSecond;
                File.WriteAllText(Path.Combine(directory, "video-editor-" + quality.ToString().ToLowerInvariant() + "-cadence-validation.json"),
                    JsonSerializer.Serialize(new { quality, expectedFrames, actualDecoded = cadence }, new JsonSerializerOptions { WriteIndented = true }));
                Require(cadence.Frames == expectedFrames, "actual MP4 decodes every planned frame including its final partial frame " + quality);
                Require(Math.Abs(cadence.FirstPresentationTicks) <= 1, "actual MP4 starts at time zero " + quality);
                long interval = TimeSpan.TicksPerSecond / quality.FramesPerSecond();
                Require(cadence.PresentationTicks.Zip(cadence.PresentationTicks.Skip(1), (first, second) => second - first)
                    .All(gap => gap > 0 && Math.Abs(gap - interval) <= 1), "actual MP4 preserves constant output cadence " + quality);
                Require(cadence.LastDurationTicks > 0 && Math.Abs(cadence.LastPresentationTicks + cadence.LastDurationTicks - source.Duration.Ticks) <= interval + 10000,
                    "actual MP4 final frame retains the source endpoint within one output frame " + quality);
                foreach (var point in new[] { (Name: "before", Seconds: 0.5), (Name: "during", Seconds: 2.0), (Name: "after", Seconds: 3.5) })
                {
                    var frame = await decoded.GetFrameAsync(TimeSpan.FromSeconds(point.Seconds));
                    var originalFrame = await source.GetFrameAsync(TimeSpan.FromSeconds(point.Seconds));
                    sourceStripe.Add(MeanBlue(originalFrame, new Int32Rect(30, 3, 570, 6)));
                    outputStripe.Add(MeanBlue(frame, new Int32Rect(30, 3, 570, 6)));
                    Require(Math.Abs(sourceStripe[^1] - outputStripe[^1]) < 20, "actual MP4 moving top stripe matches its source timestamp/orientation " + point.Name + " " + quality);
                    double blur = Delta(originalFrame, frame, new Int32Rect(40, 195, 85, 95));
                    double pixel = Delta(originalFrame, frame, new Int32Rect(170, 195, 85, 95));
                    if (point.Name == "during")
                    {
                        Require(blur > 35 && pixel > 35, "decoded MP4 contains Blur/Pixelate only during interval " + quality);
                        Require(Delta(originalFrame, frame, new Int32Rect(305, 75, 270, 48)) > 10, "decoded MP4 contains timed text " + quality);
                        Require(Delta(originalFrame, frame, new Int32Rect(345, 165, 145, 95)) > 4, "decoded MP4 contains native pointer arrow " + quality);
                    }
                    else Require(blur < 25 && pixel < 25, "decoded MP4 excludes effects " + point.Name + " interval " + quality);
                    Require(Delta(previews[point.Name], frame, new Int32Rect(20, 70, 590, 250)) < 30, "preview/export composition agrees within H.264 compression " + point.Name + " " + quality);
                    Save(frame, Path.Combine(directory, $"video-editor-output-{quality.ToString().ToLowerInvariant()}-{point.Name}.png"));
                }
                Require(outputStripe[1] - outputStripe[0] > 15 && outputStripe[2] - outputStripe[1] > 15, "actual MP4 source frames advance between all three timestamps " + quality);
                checks.Add($"{quality.Title()}: source/output moving top-stripe blue means {string.Join("/", sourceStripe.Select(value => value.ToString("0.0")))}/{string.Join("/", outputStripe.Select(value => value.ToString("0.0")))}; timestamp and vertical orientation checks passed.");
                checks.Add($"{quality.Title()}: actual edited MP4 decoded before/in/after interval; text, pointer arrow, drawings, blur and pixelation match preview within codec tolerance. Native export took {watch.Elapsed.TotalSeconds:0.0}s for {source.Duration.TotalSeconds:0.0}s of {width}×{height} video.");
            }
            Require(File.Exists(session.SourcePath), "successful export leaves source available until editor closes");
        }
        finally { editor.CloseFixture(); await editor.Completion; }
        session.Dispose();
        Require(!Directory.Exists(session.DirectoryPath), "closing the native editor releases its decoder and removes temporary source files");
        checks.Add("Closing the editor releases the preview decoder, and RecordingSession disposal removes its temporary source directory.");
        File.WriteAllText(Path.Combine(directory, "video-editor-validation.json"), JsonSerializer.Serialize(new
        {
            platform = "Windows native WPF / Media Foundation",
            sourceCommit = Environment.GetEnvironmentVariable("SLIGHTSHOT_SOURCE_COMMIT") ?? "unknown",
            source = "Moving synthetic BGRA recording. Real native editor HWND captured from composed desktop pixels. Arrow uses native automated pointer input; other annotations use labelled fixture inputs. Native sliders and buttons are operated automatically. MP4 is encoded and decoded through the production export path.",
            checks
        }, new JsonSerializerOptions { WriteIndented = true }));
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        for (int index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
        {
            var child = VisualTreeHelper.GetChild(root, index); yield return child;
            foreach (var nested in Descendants(child)) yield return nested;
        }
    }
    private static IEnumerable<Button> Buttons(Window window) => Descendants((DependencyObject)window.Content).OfType<Button>();
    private static IEnumerable<Slider> Sliders(Window window) => Descendants((DependencyObject)window.Content).OfType<Slider>();
    internal static void ClickTooltip(Window window, string tooltip) => Buttons(window).Single(button => Equals(button.ToolTip, tooltip)).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    private static void ClickContent(Window window, string content) => Buttons(window).Single(button => Equals(button.Content, content)).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    internal static async Task DragAsync(FrameworkElement surface, Point start, Point end)
    {
        var first = surface.PointToScreen(start); var last = surface.PointToScreen(end);
        Require(SetCursorPos((int)first.X, (int)first.Y), "native pointer moves to annotation start"); await Task.Delay(50);
        MouseEvent(0x0002, 0, 0, 0, UIntPtr.Zero); await Task.Delay(50);
        Require(SetCursorPos((int)last.X, (int)last.Y), "native pointer moves to annotation endpoint"); await Task.Delay(50);
        MouseEvent(0x0004, 0, 0, 0, UIntPtr.Zero); await Task.Delay(100);
    }
    internal static void CaptureWindow(Window window, string path)
    {
        Require(RecordingNative.GetWindowRect(new WindowInteropHelper(window).Handle, out var rect), "native editor screenshot bounds");
        using var bitmap = new System.Drawing.Bitmap(rect.Right - rect.Left, rect.Bottom - rect.Top);
        using var graphics = System.Drawing.Graphics.FromImage(bitmap); graphics.CopyFromScreen(rect.Left, rect.Top, 0, 0, bitmap.Size);
        bitmap.Save(path, System.Drawing.Imaging.ImageFormat.Png);
    }
    internal static void Save(BitmapSource bitmap, string path) { using var stream = File.Create(path); OutputService.Encode(bitmap, ImageFormat.Png, 1).Save(stream); }
    internal static double Delta(BitmapSource first, BitmapSource second, Int32Rect region)
    {
        int stride = region.Width * 4; var a = new byte[stride * region.Height]; var b = new byte[a.Length];
        first.CopyPixels(region, a, stride, 0); second.CopyPixels(region, b, stride, 0);
        long sum = 0; for (int index = 0; index < a.Length; index++) if (index % 4 != 3) sum += Math.Abs(a[index] - b[index]);
        return (double)sum / (region.Width * region.Height * 3);
    }
    internal static double MeanBlue(BitmapSource bitmap, Int32Rect region)
    {
        int stride = region.Width * 4; var pixels = new byte[stride * region.Height]; bitmap.CopyPixels(region, pixels, stride, 0);
        long sum = 0; for (int index = 0; index < pixels.Length; index += 4) sum += pixels[index];
        return (double)sum / (region.Width * region.Height);
    }
    private sealed class CancelOnProgress(CancellationTokenSource cancellation) : IProgress<double>
    {
        internal bool Called { get; private set; }
        public void Report(double value) { Called = true; cancellation.Cancel(); }
    }
    private static async Task ExpectCancellation(Func<Task> operation)
    {
        try { await operation(); throw new InvalidOperationException("Annotated export ignored cancellation."); }
        catch (OperationCanceledException) { }
    }
    private static void Require(bool condition, string check) { if (!condition) throw new InvalidOperationException("Video editor smoke test failed: " + check); }
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll", EntryPoint = "mouse_event")] private static extern void MouseEvent(uint flags, uint x, uint y, uint data, UIntPtr extra);
}
