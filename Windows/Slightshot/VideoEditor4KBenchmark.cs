using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text.Json;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
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
        string[] phaseNames = ["recordingFixture", "editorPreview", "primaryExport", "outputValidation", "activeCancel", "balancedExport", "balancedValidation", "stepFixture"];
        var phasePrivate = new long[phaseNames.Length]; var phaseWorking = new long[phaseNames.Length]; int phase = 0;
        using var monitoring = new CancellationTokenSource();
        Task monitor = Task.Run(async () =>
        {
            while (!monitoring.IsCancellationRequested)
            {
                process.Refresh(); peakPrivate = Math.Max(peakPrivate, process.PrivateMemorySize64); peakWorking = Math.Max(peakWorking, process.WorkingSet64);
                int measuredPhase = Volatile.Read(ref phase);
                phasePrivate[measuredPhase] = Math.Max(phasePrivate[measuredPhase], process.PrivateMemorySize64);
                phaseWorking[measuredPhase] = Math.Max(phaseWorking[measuredPhase], process.WorkingSet64);
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
        // Readable invented account text at fit-view size makes weak effects
        // visible in actual source/MP4 captures, alongside the high-frequency
        // checker region used for numerical codec/effect validation.
        var baseImage = BitmapSource.Create(width, height, 96, 96, PixelFormats.Pbgra32, null, pixels, width * 4);
        var fixture = new DrawingVisual();
        using (var dc = fixture.RenderOpen())
        {
            dc.DrawImage(baseImage, new Rect(0, 0, width, height));
            foreach (int x in new[] { 228, 1008 })
            {
                dc.DrawRectangle(Brushes.White, null, new Rect(x, 1210, 540, 250));
                dc.DrawText(AnnotationRenderer.Text("ACCT 1234", 84, Brushes.Black), new Point(x + 20, 1220));
                dc.DrawText(AnnotationRenderer.Text("KEY 5678", 84, Brushes.Black), new Point(x + 20, 1340));
            }
        }
        var accountSource = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        accountSource.Render(fixture); accountSource.CopyPixels(pixels, width * 4, 0);
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
        var seeks = new List<double>(); var metrics = new VideoExportMetrics(); var cancelMetrics = new VideoExportMetrics(); var stepMetrics = new VideoExportMetrics();
        double exportSeconds = 0, cancellationSeconds = 0, viewScale = 1;
        double effectiveRasterScale = 1;
        double blurReferenceDelta = 0, pixelReferenceDelta = 0;
        double stepDiameterPoints = 0, renderedStepFillPoints = 0;
        double cancelRequestedWallSinceStart = 0; int actualFramesBeforeCancel = 0;
        string retainedSourceSha256 = "", retainedDestinationSha256 = "";
        var sourceStripe = new List<double>(); var outputStripe = new List<double>();
        BalancedEvidence? balanced = null;
        VideoDecodedStatistics? highDecodedStatistics = null;
        try
        {
            Volatile.Write(ref phase, 1);
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
            effectiveRasterScale = annotations.Single(mark => mark.Annotation.Tool == Tool.Pixelate).Annotation.EffectiveRasterScale;
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
            Volatile.Write(ref phase, 2);
            await VideoAnnotationExport.SaveAsync(session.SourcePath, output, RecordingQuality.High, width, height, annotations, CancellationToken.None, metrics: metrics);
            exportSeconds = export.Elapsed.TotalSeconds;
            heartbeat.Stop();
            Volatile.Write(ref phase, 3);
            highDecodedStatistics = await VideoSequentialDecoder.InspectAsync(output, width, height);
            var highCadenceFailures = DecodedCadenceFailures(highDecodedStatistics, source.Duration, RecordingQuality.High);
            File.WriteAllText(Path.Combine(directory, "video-editor-4k-high-cadence-validation.json"), JsonSerializer.Serialize(new
            {
                platform = "Windows native Media Foundation full NV12 decode",
                sourceCommit = Environment.GetEnvironmentVariable("SLIGHTSHOT_SOURCE_COMMIT") ?? "unknown",
                expectedDecodedFrames = ExpectedFrames(source.Duration, RecordingQuality.High),
                submittedFrames = metrics.Frames, decodedStatistics = highDecodedStatistics,
                encoderDiagnostics = metrics.EncoderDiagnostics, validationFailures = highCadenceFailures
            }, new JsonSerializerOptions { WriteIndented = true }));
            Require(highCadenceFailures.Count == 0, string.Join("; ", highCadenceFailures));
            using var decoded = await VideoFrameSource.OpenAsync(output);
            Require(decoded.Width == width && decoded.Height == height, "actual MP4 retains 3840×2160 source dimensions");
            foreach (double seconds in new[] { 0.15, 0.7, 1.25 })
            {
                var original = await source.GetFrameAsync(TimeSpan.FromSeconds(seconds));
                var rendered = VideoAnnotationRenderer.Render(original, TimeSpan.FromSeconds(seconds), annotations);
                var frame = await decoded.GetFrameAsync(TimeSpan.FromSeconds(seconds));
                sourceStripe.Add(VideoEditorSmokeTest.MeanBlue(original, new Int32Rect(180, 12, 3300, 40)));
                outputStripe.Add(VideoEditorSmokeTest.MeanBlue(frame, new Int32Rect(180, 12, 3300, 40)));
                Require(Math.Abs(sourceStripe[^1] - outputStripe[^1]) < 20, "4K MP4 moving top stripe matches its source timestamp and vertical orientation");
                double blur = VideoEditorSmokeTest.Delta(original, frame, new Int32Rect(240, 1180, 450, 530));
                double pixel = VideoEditorSmokeTest.Delta(original, frame, new Int32Rect(1030, 1180, 450, 530));
                Require(seconds is > .35 and < 1.1 ? blur > 35 && pixel > 35 : blur < 25 && pixel < 25, "4K MP4 effects only during interval");
                Require(VideoEditorSmokeTest.Delta(rendered, frame, new Int32Rect(120, 1000, 1680, 960)) < 30, "4K preview/export pixels agree within H.264 tolerance");
                if (seconds == 0.7)
                {
                    VideoEditorSmokeTest.Save(frame, Path.Combine(directory, "video-editor-4k-output-during.png"));
                    int fitWidth = Math.Max(1, (int)Math.Round(width * viewScale)); double scale = (double)fitWidth / width;
                    var fitOriginal = Fit(original, fitWidth); var fitVideo = Fit(rendered, fitWidth);
                    var referenceMarks = annotations.Where(mark => mark.Annotation.IsRasterEffect).Select(mark => mark.Annotation with
                    {
                        Points = mark.Annotation.Points.Select(point => new PointD(point.X * scale, point.Y * scale)).ToArray(), RasterScale = 1
                    }).ToArray();
                    var referenceSource = new EditorImageSource(fitOriginal, 1);
                    var screenshot = AnnotationRenderer.Flatten(referenceSource, referenceSource.Bounds, referenceMarks);
                    Int32Rect Region(int left) => new((int)(left * scale), (int)(1180 * scale), (int)(450 * scale), (int)(530 * scale));
                    blurReferenceDelta = VideoEditorSmokeTest.Delta(screenshot, fitVideo, Region(240));
                    pixelReferenceDelta = VideoEditorSmokeTest.Delta(screenshot, fitVideo, Region(1030));
                    VideoEditorSmokeTest.Save(screenshot, Path.Combine(directory, "video-editor-4k-screenshot-strength-reference.png"));
                    VideoEditorSmokeTest.Save(fitVideo, Path.Combine(directory, "video-editor-4k-fit-view-effects.png"));
                }
            }
            Require(outputStripe[1] - outputStripe[0] > 3 && outputStripe[2] - outputStripe[1] > 3, "4K MP4 source frames advance at all three timestamps");
            // This verification decoder is no longer needed by cancellation
            // or the separate Balanced/Step exports. Do not retain its graph.
            decoded.Dispose();
            Volatile.Write(ref phase, 4);
            string preserved = Path.Combine(directory, "preserved.mp4"); byte[] existing = [11, 22, 33, 44]; File.WriteAllBytes(preserved, existing);
            string sourceDigest = Convert.ToHexString(SHA256.HashData(await File.ReadAllBytesAsync(session.SourcePath)));
            using var cancel = new CancellationTokenSource();
            var cancellationStart = Stopwatch.StartNew();
            var cancelled = VideoAnnotationExport.SaveAsync(session.SourcePath, preserved, RecordingQuality.High, width, height, annotations, cancel.Token, metrics: cancelMetrics);
            bool Written() => Directory.EnumerateFiles(directory, ".slightshot-*.mp4").Any(path => new FileInfo(path).Length > 4096);
            while (!cancelled.IsCompleted && (cancelMetrics.Frames == 0 || !Written()) && cancellationStart.Elapsed < TimeSpan.FromSeconds(15)) await Task.Delay(10);
            actualFramesBeforeCancel = cancelMetrics.Frames;
            Require(!cancelled.IsCompleted && actualFramesBeforeCancel > 0 && Written(), "4K cancel happens while rendered frames and MP4 bytes are actually in flight");
            cancelRequestedWallSinceStart = cancellationStart.Elapsed.TotalSeconds;
            var cancelWatch = Stopwatch.StartNew(); cancel.Cancel();
            try { await cancelled; throw new InvalidOperationException("4K export ignored cancellation."); } catch (OperationCanceledException) { }
            cancellationSeconds = cancelWatch.Elapsed.TotalSeconds;
            Require(File.ReadAllBytes(preserved).SequenceEqual(existing) && File.Exists(session.SourcePath) && editor.History.Items.Count == 3, "4K cancellation retains destination, source and edits");
            retainedSourceSha256 = Convert.ToHexString(SHA256.HashData(await File.ReadAllBytesAsync(session.SourcePath)));
            retainedDestinationSha256 = Convert.ToHexString(SHA256.HashData(await File.ReadAllBytesAsync(preserved)));
            Require(retainedSourceSha256 == sourceDigest, "active 4K cancellation preserves source bytes exactly");
            Require(!Directory.EnumerateFiles(directory, ".slightshot-*").Any(), "4K cancellation removes staging"); File.Delete(preserved);
            // Keep the primary High/cancel workload unchanged. This separate
            // export exercises real 4K-to-1080p resizing with the same marks.
            Volatile.Write(ref phase, 5);
            balanced = await VerifyBalancedAsync(directory, session.SourcePath, source, width, height, viewScale, annotations,
                () => Volatile.Write(ref phase, 6));
            // Separate from the unchanged three-tool performance workload:
            // operate the actual Step tool and verify its real MP4 diameter.
            Volatile.Write(ref phase, 7);
            await editor.SeekAsync(TimeSpan.FromSeconds(.7));
            VideoEditorSmokeTest.ClickTooltip(editor, "Numbered steps");
            await VideoEditorSmokeTest.DragAsync(editor.Surface, new(3300, 400), new(3300, 400));
            editor.SetSelectedTiming(TimeSpan.FromSeconds(.35), TimeSpan.FromSeconds(1.1));
            var step = editor.History.Selected!.Annotation;
            stepDiameterPoints = step.StepDiameter * viewScale;
            await Task.Delay(100); editor.UpdateLayout();
            VideoEditorSmokeTest.CaptureWindow(editor, Path.Combine(directory, "video-editor-4k-step.png"));
            string stepOutput = Path.Combine(directory, "video-editor-4k-step.mp4");
            await VideoAnnotationExport.SaveAsync(session.SourcePath, stepOutput, RecordingQuality.High, width, height,
                editor.History.ExportSnapshot().Where(mark => mark.Annotation.Tool == Tool.Step).ToArray(), CancellationToken.None, metrics: stepMetrics);
            using var stepDecoded = await VideoFrameSource.OpenAsync(stepOutput);
            var stepFrame = await stepDecoded.GetFrameAsync(TimeSpan.FromSeconds(.7));
            int left = (int)Math.Floor(3300 - step.StepDiameter / 2 - 2), length = (int)Math.Ceiling(step.StepDiameter + 4);
            var line = new byte[length * 4]; stepFrame.CopyPixels(new Int32Rect(left, 400, length, 1), line, length * 4, 0);
            int first = -1, last = -1;
            for (int x = 0; x < length; x++) if (line[x * 4 + 2] > 180 && line[x * 4 + 1] < 140 && line[x * 4] < 140) { if (first < 0) first = x; last = x; }
            renderedStepFillPoints = first < 0 ? 0 : (last - first + 1) * viewScale;
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
        if (blurReferenceDelta > 18 || pixelReferenceDelta > 18) acceptance.Add("Rendered fit-view effects differ from screenshot strength by more than 18 mean channel values");
        if (Math.Abs(stepDiameterPoints - 32) > 0.01 || Math.Abs(renderedStepFillPoints - 29) > 2.5) acceptance.Add("Native numbered step does not retain its screenshot size in the actual 4K MP4");
        if (RasterEffects.PixelBlockSize * effectiveRasterScale * viewScale < 10) acceptance.Add("Pixelation weaker than screenshot 12-point blocks in fit view");
        File.WriteAllText(Path.Combine(directory, "video-editor-4k-validation.json"), JsonSerializer.Serialize(new
        {
            platform = "Windows native WPF / Media Foundation", baseline,
            sourceCommit = Environment.GetEnvironmentVariable("SLIGHTSHOT_SOURCE_COMMIT") ?? "unknown",
            fixture = "3840×2160 synthetic moving recording, high-frequency checker and invented readable ACCT1234 / KEY5678 text, native pointer-drawn blur/pixelate plus fixture caption, 0.35–1.1s interval, actual High 30fps MP4. Separate Balanced 1920×1080 export with decoded before/during/after source, composition and screenshot-strength checks after High/cancel; its throughput and UI heartbeat are reported separately. Separate native Step-button/click fixture and actual MP4 diameter check after the three-tool benchmark. Native editor HWND screenshots; no personal source data.",
            durationSeconds = source.Duration.TotalSeconds, exportSeconds, frames = metrics.Frames, exportFramesPerSecond = metrics.Frames / exportSeconds,
            metrics.DecodeMilliseconds, metrics.RenderMilliseconds, metrics.BufferWaitMilliseconds,
            metrics.WriterMilliseconds, metrics.ResizeMilliseconds, metrics.MaximumWriterQueuedBytes,
            encoderDiagnostics = metrics.EncoderDiagnostics, actualHighDecodedStatistics = highDecodedStatistics,
            exportMemorySnapshots = metrics.MemorySnapshots, cancelMemorySnapshots = cancelMetrics.MemorySnapshots, stepMemorySnapshots = stepMetrics.MemorySnapshots,
            seekMilliseconds = seeks, maxDispatcherGapMilliseconds = maxDispatcherGap, peakPrivateMiB = peakPrivate / 1048576.0, peakWorkingMiB = peakWorking / 1048576.0,
            memoryPhases = phaseNames.Select((name, index) => new { name, peakPrivateMiB = phasePrivate[index] / 1048576.0, peakWorkingMiB = phaseWorking[index] / 1048576.0 }).ToArray(),
            sourceTopStripeBlueMeans = sourceStripe, outputTopStripeBlueMeans = outputStripe,
            cancellationSeconds, viewScale, effectiveBlurPoints = RasterEffects.BlurRadius * effectiveRasterScale * viewScale,
            effectivePixelBlockPoints = RasterEffects.PixelBlockSize * effectiveRasterScale * viewScale,
            blurScreenshotReferenceMeanDelta = blurReferenceDelta, pixelScreenshotReferenceMeanDelta = pixelReferenceDelta,
            stepDiameterPoints, renderedStepFillPoints,
            cancelRequestedWallSinceStart, actualFramesBeforeCancel, retainedSourceSha256, retainedDestinationSha256,
            balancedResize = balanced,
            acceptanceFailures = acceptance
        }, new JsonSerializerOptions { WriteIndented = true }));
        Require(baseline || acceptance.Count == 0, string.Join("; ", acceptance));
    }
    private static async Task<BalancedEvidence> VerifyBalancedAsync(string directory, string sourcePath, VideoFrameSource source,
        int sourceWidth, int sourceHeight, double viewScale, IReadOnlyList<TimedAnnotation> annotations, Action validating)
    {
        var quality = RecordingQuality.Balanced;
        var expected = quality.Dimensions(sourceWidth, sourceHeight);
        Require(expected.Width == 1920 && expected.Height == 1080, "Balanced fixture exercises the 4K-to-1920×1080 quality profile");
        string output = Path.Combine(directory, "video-editor-4k-balanced.mp4");
        var metrics = new VideoExportMetrics();
        double maxDispatcherGap = 0;
        long lastBeat = Stopwatch.GetTimestamp();
        var heartbeat = new DispatcherTimer(DispatcherPriority.Input) { Interval = TimeSpan.FromMilliseconds(16) };
        heartbeat.Tick += (_, _) =>
        {
            long now = Stopwatch.GetTimestamp();
            maxDispatcherGap = Math.Max(maxDispatcherGap, Stopwatch.GetElapsedTime(lastBeat, now).TotalMilliseconds);
            lastBeat = now;
        };
        var watch = Stopwatch.StartNew();
        heartbeat.Start();
        try
        {
            await VideoAnnotationExport.SaveAsync(sourcePath, output, quality, sourceWidth, sourceHeight, annotations,
                CancellationToken.None, metrics: metrics);
        }
        finally
        {
            // Include the final export continuation in this optional metric,
            // even if it completes before the next dispatcher timer tick.
            maxDispatcherGap = Math.Max(maxDispatcherGap, Stopwatch.GetElapsedTime(lastBeat).TotalMilliseconds);
            heartbeat.Stop();
        }
        double exportSeconds = watch.Elapsed.TotalSeconds;
        validating();
        var actualDecoded = await VideoSequentialDecoder.InspectAsync(output, expected.Width, expected.Height);
        using var decoded = await VideoFrameSource.OpenAsync(output);
        Require(decoded.Width == expected.Width && decoded.Height == expected.Height, "actual Balanced MP4 is 1920×1080");
        long expectedFrames = ExpectedFrames(source.Duration, quality);
        double outputScale = (double)decoded.Width / sourceWidth;
        int fitWidth = Math.Max(1, (int)Math.Round(sourceWidth * viewScale));
        double fitScale = (double)fitWidth / sourceWidth;
        var checks = new List<BalancedFrameEvidence>();
        double blurReferenceDelta = 0, pixelReferenceDelta = 0;
        foreach (double seconds in new[] { 0.15, 0.7, 1.25 })
        {
            string name = seconds < .35 ? "before" : seconds < 1.1 ? "during" : "after";
            var position = TimeSpan.FromSeconds(seconds);
            var original = await source.GetFrameAsync(position);
            var composed = VideoAnnotationRenderer.Render(original, position, annotations);
            var resizedSource = Fit(original, decoded.Width);
            var resizedComposition = Fit(composed, decoded.Width);
            var frame = await decoded.GetFrameAsync(position);
            VideoEditorSmokeTest.Save(frame, Path.Combine(directory, "video-editor-4k-balanced-" + name + ".png"));
            double sourceStripe = VideoEditorSmokeTest.MeanBlue(resizedSource, ScaledRegion(180, 12, 3300, 40, outputScale));
            double outputStripe = VideoEditorSmokeTest.MeanBlue(frame, ScaledRegion(180, 12, 3300, 40, outputScale));
            double blur = VideoEditorSmokeTest.Delta(resizedSource, frame, ScaledRegion(240, 1180, 450, 530, outputScale));
            double pixel = VideoEditorSmokeTest.Delta(resizedSource, frame, ScaledRegion(1030, 1180, 450, 530, outputScale));
            double caption = VideoEditorSmokeTest.Delta(resizedSource, frame, ScaledRegion(1830, 550, 1500, 200, outputScale));
            double composition = VideoEditorSmokeTest.Delta(resizedComposition, frame, ScaledRegion(120, 1000, 1680, 960, outputScale));
            double captionComposition = VideoEditorSmokeTest.Delta(resizedComposition, frame, ScaledRegion(1830, 550, 1500, 200, outputScale));
            checks.Add(new(seconds, name, sourceStripe, outputStripe, blur, pixel, caption, composition, captionComposition));
            if (name == "during")
            {
                var fitOriginal = Fit(original, fitWidth);
                var fitVideo = Fit(frame, fitWidth);
                var referenceMarks = annotations.Where(mark => mark.Annotation.IsRasterEffect).Select(mark => mark.Annotation with
                {
                    Points = mark.Annotation.Points.Select(point => new PointD(point.X * fitScale, point.Y * fitScale)).ToArray(), RasterScale = 1
                }).ToArray();
                var referenceSource = new EditorImageSource(fitOriginal, 1);
                var screenshot = AnnotationRenderer.Flatten(referenceSource, referenceSource.Bounds, referenceMarks);
                blurReferenceDelta = VideoEditorSmokeTest.Delta(screenshot, fitVideo, ScaledRegion(240, 1180, 450, 530, fitScale));
                pixelReferenceDelta = VideoEditorSmokeTest.Delta(screenshot, fitVideo, ScaledRegion(1030, 1180, 450, 530, fitScale));
                VideoEditorSmokeTest.Save(resizedComposition, Path.Combine(directory, "video-editor-4k-balanced-composition-reference.png"));
                VideoEditorSmokeTest.Save(screenshot, Path.Combine(directory, "video-editor-4k-balanced-screenshot-strength-reference.png"));
                VideoEditorSmokeTest.Save(fitVideo, Path.Combine(directory, "video-editor-4k-balanced-fit-view-effects.png"));
            }
        }
        var failures = DecodedCadenceFailures(actualDecoded, source.Duration, quality);
        void Check(bool condition, string message) { if (!condition) failures.Add(message); }
        Check(Math.Abs((decoded.Duration - source.Duration).TotalMilliseconds) <= 1000.0 / quality.FramesPerSecond() + 5,
            "Balanced resizing preserves the source duration within one output frame");
        Check(metrics.Frames == expectedFrames, "Balanced submits every expected 24fps output frame");
        foreach (var point in checks)
        {
            string name = point.IntervalState;
            Check(Math.Abs(point.SourceTopStripeBlueMean - point.OutputTopStripeBlueMean) < 20,
                "Balanced MP4 moving top stripe matches its source timestamp and vertical orientation " + name);
            Check(name == "during" ? point.BlurMeanDeltaFromSource > 35 && point.PixelationMeanDeltaFromSource > 35 :
                point.BlurMeanDeltaFromSource < 25 && point.PixelationMeanDeltaFromSource < 25,
                "Balanced MP4 blur and pixelation appear only during their interval " + name);
            Check(name == "during" ? point.CaptionMeanDeltaFromSource > 10 : point.CaptionMeanDeltaFromSource < 25,
                "Balanced MP4 timed caption retains its source position after resizing " + name);
            Check(point.ResizedCompositionMeanDelta < 30 && point.CaptionCompositionMeanDelta < 30,
                "Balanced resized source-coordinate composition agrees with actual MP4 pixels within H.264 tolerance " + name);
        }
        Check(blurReferenceDelta <= 18 && pixelReferenceDelta <= 18,
            "actual Balanced MP4 retains screenshot-equivalent fit-view blur/pixelation strength after downscaling");
        Check(checks[1].OutputTopStripeBlueMean - checks[0].OutputTopStripeBlueMean > 3 &&
            checks[2].OutputTopStripeBlueMean - checks[1].OutputTopStripeBlueMean > 3,
            "Balanced MP4 frames advance at all three source timestamps");
        var result = new BalancedEvidence("Balanced", Path.GetFileName(output), sourceWidth, sourceHeight, decoded.Width, decoded.Height,
            quality.FramesPerSecond(), decoded.Duration.TotalSeconds, expectedFrames, metrics.Frames, exportSeconds,
            metrics.Frames / exportSeconds, maxDispatcherGap, metrics.DecodeMilliseconds, metrics.RenderMilliseconds,
            metrics.BufferWaitMilliseconds, metrics.WriterMilliseconds, metrics.ResizeMilliseconds, metrics.MaximumWriterQueuedBytes,
            actualDecoded, metrics.EncoderDiagnostics, metrics.MemorySnapshots, checks, blurReferenceDelta, pixelReferenceDelta, failures);
        File.WriteAllText(Path.Combine(directory, "video-editor-4k-balanced-validation.json"), JsonSerializer.Serialize(new
        {
            platform = "Windows native WPF / Media Foundation",
            sourceCommit = Environment.GetEnvironmentVariable("SLIGHTSHOT_SOURCE_COMMIT") ?? "unknown",
            fixture = "Separate actual Balanced export of the same synthetic 4K recording and three timed annotations after primary High/cancel. PNGs decode the real MP4. Composition reference renders source-coordinate annotations before resizing; screenshot reference uses the existing screenshot renderer at editor fit width. Throughput and export UI heartbeat are optional measured results; primary High acceptance thresholds remain unchanged.",
            validation = result
        }, new JsonSerializerOptions { WriteIndented = true }));
        Require(failures.Count == 0, string.Join("; ", failures));
        return result;
    }
    private sealed record BalancedEvidence(string Quality, string OutputFile, int SourceWidth, int SourceHeight,
        int ActualOutputWidth, int ActualOutputHeight, int ConfiguredFramesPerSecond, double ActualDurationSeconds,
        long ExpectedSubmittedFrames, int SubmittedFrames, double ExportSeconds, double ExportFramesPerSecond,
        double MaxDispatcherGapMilliseconds, double DecodeMilliseconds, double RenderMilliseconds, double BufferWaitMilliseconds,
        double WriterMilliseconds, double ResizeMilliseconds, uint MaximumWriterQueuedBytes,
        VideoDecodedStatistics ActualDecodedStatistics, VideoEncoderDiagnostics EncoderDiagnostics,
        IReadOnlyList<VideoExportMemorySnapshot> MemorySnapshots, IReadOnlyList<BalancedFrameEvidence> Frames,
        double BlurScreenshotReferenceMeanDelta, double PixelScreenshotReferenceMeanDelta, IReadOnlyList<string> ValidationFailures);
    private sealed record BalancedFrameEvidence(double RequestedSeconds, string IntervalState, double SourceTopStripeBlueMean,
        double OutputTopStripeBlueMean, double BlurMeanDeltaFromSource, double PixelationMeanDeltaFromSource,
        double CaptionMeanDeltaFromSource, double ResizedCompositionMeanDelta, double CaptionCompositionMeanDelta);
    private static Int32Rect ScaledRegion(int x, int y, int width, int height, double scale) =>
        new((int)Math.Round(x * scale), (int)Math.Round(y * scale), Math.Max(1, (int)Math.Round(width * scale)), Math.Max(1, (int)Math.Round(height * scale)));
    private static long ExpectedFrames(TimeSpan duration, RecordingQuality quality) =>
        (duration.Ticks * quality.FramesPerSecond() + TimeSpan.TicksPerSecond - 1) / TimeSpan.TicksPerSecond;
    private static List<string> DecodedCadenceFailures(VideoDecodedStatistics actual, TimeSpan duration, RecordingQuality quality)
    {
        var failures = new List<string>();
        string label = quality.Title();
        long expected = ExpectedFrames(duration, quality);
        if (actual.Frames != expected) failures.Add($"{label} MP4 actually decodes {actual.Frames} frames; expected {expected} from source duration and quality cadence");
        if (actual.Frames <= 0 || actual.PresentationTicks.Count != actual.Frames)
        {
            failures.Add(label + " MP4 does not have a presentation timestamp for every decoded frame"); return failures;
        }
        if (Math.Abs(actual.FirstPresentationTicks) > 1) failures.Add(label + " MP4 first actual presentation timestamp is not zero within one 100ns tick");
        long frameTicks = TimeSpan.TicksPerSecond / quality.FramesPerSecond();
        if (actual.PresentationTicks.Zip(actual.PresentationTicks.Skip(1), (first, second) => second - first)
            .Any(gap => gap <= 0 || Math.Abs(gap - frameTicks) > 1))
            failures.Add(label + " MP4 decoded presentation timestamps do not advance at the configured cadence within one 100ns tick");
        long expectedLastPresentation = (expected - 1) * TimeSpan.TicksPerSecond / quality.FramesPerSecond();
        long expectedLastDuration = Math.Min(frameTicks, duration.Ticks - expectedLastPresentation);
        // MP4 timescale conversion can round sample lengths. One millisecond
        // admits that conversion, but cannot hide the missing 8.3ms final sample
        // observed in the original Balanced 4K output or an extra full frame.
        const long endToleranceTicks = TimeSpan.TicksPerMillisecond;
        if (actual.LastDurationTicks <= 0 || Math.Abs(actual.LastDurationTicks - expectedLastDuration) > endToleranceTicks)
            failures.Add(label + " MP4 does not preserve the planned final partial-frame duration within 1ms");
        if (Math.Abs(actual.LastPresentationTicks + actual.LastDurationTicks - duration.Ticks) > endToleranceTicks)
            failures.Add(label + " MP4 decoded frame coverage does not preserve the source end time within 1ms");
        return failures;
    }
    private static BitmapSource Fit(BitmapSource bitmap, int width)
    {
        int height = Math.Max(1, (int)Math.Round((double)width * bitmap.PixelHeight / bitmap.PixelWidth));
        var visual = new DrawingVisual(); using (var dc = visual.RenderOpen()) dc.DrawImage(bitmap, new Rect(0, 0, width, height));
        var result = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32); result.Render(visual); result.Freeze(); return result;
    }
    private static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException("4K video benchmark failed: " + message); }
}
