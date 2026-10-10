using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Slightshot.Core;

namespace Slightshot;

// Bounded real 4K recording/editor/export benchmark; no desktop source data.
// Baseline mode reports unmet limits before an optimization changes the path.
internal static class VideoEditor4KBenchmark
{
    internal static async Task RunAsync(string directory)
    {
        directory = Path.GetFullPath(directory); Directory.CreateDirectory(directory);
        bool baseline = Environment.GetEnvironmentVariable("SLIGHTSHOT_VIDEO_BENCHMARK_BASELINE") == "1";
        const int width = 3840, height = 2160;
        var process = Process.GetCurrentProcess();
        long peakPrivate = 0, peakWorking = 0;
        using var monitoring = new CancellationTokenSource();
        Task monitor = Task.Run(async () =>
        {
            while (!monitoring.IsCancellationRequested)
            {
                process.Refresh(); peakPrivate = Math.Max(peakPrivate, process.PrivateMemorySize64); peakWorking = Math.Max(peakWorking, process.WorkingSet64);
                try { await Task.Delay(40, monitoring.Token); } catch (OperationCanceledException) { break; }
            }
        });
        double maxDispatcherGap = 0;
        long lastBeat = Stopwatch.GetTimestamp();
        var heartbeat = new DispatcherTimer(DispatcherPriority.Input) { Interval = TimeSpan.FromMilliseconds(16) };
        heartbeat.Tick += (_, _) => { long now = Stopwatch.GetTimestamp(); maxDispatcherGap = Math.Max(maxDispatcherGap, Stopwatch.GetElapsedTime(lastBeat, now).TotalMilliseconds); lastBeat = now; };
        var pixels = new byte[width * height * 4];
        for (int y = 0; y < height; y++) for (int x = 0; x < width; x++)
        {
            int offset = (y * width + x) * 4;
            bool pattern = x is >= 120 and < 1800 && y is >= 1000 and < 1960;
            byte shade = pattern ? ((x / 8 + y / 8) % 2 == 0 ? (byte)25 : (byte)230) : (byte)238;
            pixels[offset] = shade; pixels[offset + 1] = shade; pixels[offset + 2] = shade; pixels[offset + 3] = 255;
        }
        int count = 0;
        using var session = new RecordingSession(width, height, target =>
        {
            Buffer.BlockCopy(pixels, 0, target, 0, pixels.Length);
            int number = Interlocked.Increment(ref count);
            for (int y = 0; y < 72; y++) for (int x = 0; x < width; x++) target[(y * width + x) * 4] = (byte)(number % 200);
        });
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        session.Started += () => started.TrySetResult();
        Task recording = session.RunAsync();
        await Task.WhenAny(started.Task, recording).WaitAsync(TimeSpan.FromSeconds(30));
        if (recording.IsCompleted) await recording;
        await started.Task.WaitAsync(TimeSpan.FromSeconds(30));
        await Task.Delay(1600); session.Stop(); await recording.WaitAsync(TimeSpan.FromSeconds(30));
        Require(count > 10, "real 4K moving frames encoded");
        File.Copy(session.SourcePath, Path.Combine(directory, "video-editor-4k-source.mp4"), true);
        var source = await VideoFrameSource.OpenAsync(session.SourcePath);
        var editor = new VideoEditorWindow(source, new Settings { AnnotationColor = "#FF3B30", LineWidth = 5, FontSize = 24 }, _ => Task.FromResult(false), true);
        var seeks = new List<double>(); var metrics = new VideoExportMetrics();
        double exportSeconds = 0, cancellationSeconds = 0, viewScale = 1;
        try
        {
            editor.Show(); editor.Activate(); editor.UpdateLayout(); heartbeat.Start(); lastBeat = Stopwatch.GetTimestamp();
            await editor.InitializeAsync(); await Task.Delay(100);
            viewScale = editor.Surface.ViewScale;
            editor.Surface.ActiveTool = Tool.Blur;
            await VideoEditorSmokeTest.DragAsync(editor.Surface, new(168, 1098), new(828, 1830));
            editor.SetSelectedTiming(TimeSpan.FromSeconds(0.35), TimeSpan.FromSeconds(1.1));
            editor.Surface.ActiveTool = Tool.Pixelate;
            await VideoEditorSmokeTest.DragAsync(editor.Surface, new(948, 1098), new(1620, 1830));
            editor.SetSelectedTiming(TimeSpan.FromSeconds(0.35), TimeSpan.FromSeconds(1.1));
            editor.AddAnnotation(new(Tool.Text, [new(1830, 550)], "#0A84FF", 30, 120, "4K • timed effects"));
            editor.SetSelectedTiming(TimeSpan.FromSeconds(0.35), TimeSpan.FromSeconds(1.1));
            editor.Surface.ActiveTool = null;
            var annotations = editor.History.ExportSnapshot();
            foreach (double seconds in new[] { 0.15, 0.7, 1.25 })
            {
                var watch = Stopwatch.StartNew(); await editor.SeekAsync(TimeSpan.FromSeconds(seconds));
                await editor.Dispatcher.InvokeAsync(() => editor.UpdateLayout(), DispatcherPriority.Render); await Task.Delay(30);
                seeks.Add(watch.Elapsed.TotalMilliseconds);
                VideoEditorSmokeTest.CaptureWindow(editor, Path.Combine(directory, "video-editor-4k-" + (seconds < .35 ? "before" : seconds < 1.1 ? "during" : "after") + ".png"));
            }
            await editor.SeekAsync(TimeSpan.FromSeconds(0.4)); editor.Play(); await Task.Delay(750); editor.Pause();
            var export = Stopwatch.StartNew();
            string output = Path.Combine(directory, "video-editor-4k-high.mp4");
            await VideoAnnotationExport.SaveAsync(session.SourcePath, output, RecordingQuality.High, width, height, annotations, CancellationToken.None, metrics: metrics);
            exportSeconds = export.Elapsed.TotalSeconds;
            heartbeat.Stop();
            using var decoded = await VideoFrameSource.OpenAsync(output);
            Require(decoded.Width == width && decoded.Height == height, "actual MP4 retains 3840×2160 source dimensions");
            foreach (double seconds in new[] { 0.15, 0.7, 1.25 })
            {
                var original = await source.GetFrameAsync(TimeSpan.FromSeconds(seconds));
                var rendered = VideoAnnotationRenderer.Render(original, TimeSpan.FromSeconds(seconds), annotations);
                var frame = await decoded.GetFrameAsync(TimeSpan.FromSeconds(seconds));
                double blur = VideoEditorSmokeTest.Delta(original, frame, new Int32Rect(240, 1180, 450, 530));
                double pixel = VideoEditorSmokeTest.Delta(original, frame, new Int32Rect(1030, 1180, 450, 530));
                Require(seconds is > .35 and < 1.1 ? blur > 35 && pixel > 35 : blur < 25 && pixel < 25, "4K MP4 effects only during interval");
                Require(VideoEditorSmokeTest.Delta(rendered, frame, new Int32Rect(120, 1000, 1680, 960)) < 30, "4K preview/export pixels agree within H.264 tolerance");
                if (seconds == 0.7) VideoEditorSmokeTest.Save(frame, Path.Combine(directory, "video-editor-4k-output-during.png"));
            }
            string preserved = Path.Combine(directory, "preserved.mp4"); byte[] existing = [11, 22, 33, 44]; File.WriteAllBytes(preserved, existing);
            using var cancel = new CancellationTokenSource();
            var cancelWatch = Stopwatch.StartNew();
            var cancelled = VideoAnnotationExport.SaveAsync(session.SourcePath, preserved, RecordingQuality.High, width, height, annotations, cancel.Token);
            await Task.Delay(100); cancel.Cancel();
            try { await cancelled; throw new InvalidOperationException("4K export ignored cancellation."); } catch (OperationCanceledException) { }
            cancellationSeconds = cancelWatch.Elapsed.TotalSeconds;
            Require(File.ReadAllBytes(preserved).SequenceEqual(existing) && File.Exists(session.SourcePath) && editor.History.Items.Count == 3, "4K cancellation retains destination, source and edits");
            Require(!Directory.EnumerateFiles(directory, ".slightshot-*").Any(), "4K cancellation removes staging"); File.Delete(preserved);
        }
        finally
        {
            heartbeat.Stop(); editor.CloseFixture(); await editor.Completion;
            monitoring.Cancel(); await monitor;
        }
        var acceptance = new List<string>();
        if (metrics.Frames / exportSeconds < 8) acceptance.Add("4K export slower than 8 fps");
        if (maxDispatcherGap > 250) acceptance.Add("UI blocked for more than 250 ms");
        if (peakPrivate > 1536L * 1024 * 1024) acceptance.Add("Private bytes exceed bounded 1.5 GiB budget");
        if (cancellationSeconds > 5) acceptance.Add("4K cancellation exceeds 5 seconds");
        // The production gesture currently stores no view-normalized raster
        // strength. The baseline captures this independently of pixel delta.
        double effectiveRasterScale = 1;
        if (RasterEffects.PixelBlockSize * effectiveRasterScale * viewScale < 10) acceptance.Add("Pixelation weaker than screenshot 12-point blocks in fit view");
        File.WriteAllText(Path.Combine(directory, "video-editor-4k-validation.json"), JsonSerializer.Serialize(new
        {
            platform = "Windows native WPF / Media Foundation", baseline,
            sourceCommit = Environment.GetEnvironmentVariable("SLIGHTSHOT_SOURCE_COMMIT") ?? "unknown",
            fixture = "3840×2160 synthetic moving recording, native pointer-drawn blur/pixelate, 0.35–1.1s interval, actual High 30fps MP4. Native editor HWND screenshots; no personal source data.",
            durationSeconds = source.Duration.TotalSeconds, exportSeconds, frames = metrics.Frames, exportFramesPerSecond = metrics.Frames / exportSeconds,
            metrics.DecodeMilliseconds, metrics.RenderMilliseconds, metrics.CopyMilliseconds,
            seekMilliseconds = seeks, maxDispatcherGapMilliseconds = maxDispatcherGap, peakPrivateMiB = peakPrivate / 1048576.0, peakWorkingMiB = peakWorking / 1048576.0,
            cancellationSeconds, viewScale, effectiveBlurPoints = RasterEffects.BlurRadius * effectiveRasterScale * viewScale,
            effectivePixelBlockPoints = RasterEffects.PixelBlockSize * effectiveRasterScale * viewScale,
            acceptanceFailures = acceptance
        }, new JsonSerializerOptions { WriteIndented = true }));
        Require(baseline || acceptance.Count == 0, string.Join("; ", acceptance));
    }
    private static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException("4K video benchmark failed: " + message); }
}
