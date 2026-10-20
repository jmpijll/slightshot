using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Windows.Media.Editing;
using Windows.Media.MediaProperties;
using Windows.Storage;
using Slightshot.Core;

namespace Slightshot;

// Real Windows H.264 encode/decode/transcode exercised with moving synthetic
// frames. This validates native media, not interactive GDI desktop capture.
internal static class RecordingSmokeTest
{
    internal static async Task RunAsync(string directory)
    {
        directory = Path.GetFullPath(directory); Directory.CreateDirectory(directory);
        const int width = 1600, height = 900;
        int frame = 0;
        var buffers = new HashSet<byte[]>();
        var colors = new byte[][] { [16, 24, 224, 255], [224, 24, 16, 255], [24, 224, 16, 255] };
        RecordingSession? session = null;
        void Pixels(byte[] bytes)
        {
            buffers.Add(bytes); int number = Interlocked.Increment(ref frame);
            byte[] color = colors[Math.Min(2, (int)(session!.Duration.TotalSeconds / 2))];
            for (int y = 0; y < height; y++) for (int x = 0; x < width; x++)
            {
                int i = (y * width + x) * 4;
                // Stable center colors make early buffer reuse observable after
                // native encode/decode; a moving top stripe keeps frames live.
                bytes[i] = y < 10 ? (byte)(number % 256) : color[0];
                bytes[i + 1] = color[1]; bytes[i + 2] = color[2]; bytes[i + 3] = 255;
            }
        }
        var checks = new List<string>();
        await ValidateControlsAsync(directory, checks);
        session = new RecordingSession(width, height, Pixels);
        string temporary = session.DirectoryPath;
        try
        {
            var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            session.Started += () => started.TrySetResult();
            Task recording = session.RunAsync();
            await Task.WhenAny(started.Task, recording).WaitAsync(TimeSpan.FromSeconds(30));
            if (recording.IsCompleted) await recording;
            await started.Task.WaitAsync(TimeSpan.FromSeconds(30));
            await Task.Delay(6200); session.Stop(); session.Stop();
            await recording.WaitAsync(TimeSpan.FromSeconds(30));
            Require(frame >= 30, "live frame provider was sampled repeatedly during the bounded soak");
            Require(buffers.Count <= 4 && frame > buffers.Count, "native Processed callbacks recycled a bounded set of frame arrays");
            var source = await StorageFile.GetFileFromPathAsync(session.SourcePath);
            var metadata = await source.Properties.GetVideoPropertiesAsync();
            Require(metadata.Width == width && metadata.Height == height && metadata.Duration.TotalSeconds > 0.1, "source contains playable H.264 video at selected dimensions");
            var sourceComposition = new MediaComposition(); sourceComposition.Clips.Add(await MediaClip.CreateFromFileAsync(source));
            for (int index = 0; index < colors.Length; index++)
                await RequireDecodedColorAsync(sourceComposition, TimeSpan.FromSeconds(index * 2 + 0.5), colors[index]);
            checks.Add($"Six-second native soak encoded {frame} frames using {buffers.Count} distinct managed arrays; real Processed callbacks permitted reuse. Decoded source frames retained red/blue/green center colors across reuse, and repeated Stop finalized the MP4.");
            foreach (var quality in Enum.GetValues<RecordingQuality>())
            {
                string path = Path.Combine(directory, $"recording-{quality.ToString().ToLowerInvariant()}.mp4");
                await RecordingExport.SaveAsync(session.SourcePath, path, quality, width, height, CancellationToken.None);
                var file = await StorageFile.GetFileFromPathAsync(path);
                var profile = await MediaEncodingProfile.CreateFromFileAsync(file);
                var video = await file.Properties.GetVideoPropertiesAsync();
                var expected = quality.Dimensions(width, height);
                Require(profile.Video.Width == expected.Width && profile.Video.Height == expected.Height, $"{quality} output dimensions");
                double rate = (double)profile.Video.FrameRate.Numerator / profile.Video.FrameRate.Denominator;
                Require(Math.Abs(rate - quality.FramesPerSecond()) < 0.1, $"{quality} output frame rate");
                Require(video.Duration.TotalSeconds > 0.1, $"{quality} output duration");
                // Decode an actual movie frame through Windows' media pipeline.
                var composition = new MediaComposition(); composition.Clips.Add(await MediaClip.CreateFromFileAsync(file));
                using var thumbnail = await composition.GetThumbnailAsync(TimeSpan.FromMilliseconds(100), 160, 90, VideoFramePrecision.NearestFrame);
                var image = await Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(thumbnail);
                Require(image.PixelWidth > 0 && image.PixelHeight > 0, $"{quality} video frame decodes");
                checks.Add($"{quality.Title()}: {expected.Width}×{expected.Height}, {rate:0} fps, {new FileInfo(path).Length} bytes, native frame decode passed.");
            }
            string existing = Path.Combine(directory, "preserved.mp4"); byte[] original = [10, 20, 30, 40]; File.WriteAllBytes(existing, original);
            using (var cancellation = new CancellationTokenSource())
            {
                cancellation.Cancel();
                await ExpectCancellation(() => RecordingExport.SaveAsync(session.SourcePath, existing, RecordingQuality.High, width, height, cancellation.Token));
            }
            Require(File.ReadAllBytes(existing).SequenceEqual(original), "early cancel preserves existing destination");
            using (var cancellation = new CancellationTokenSource())
            {
                var progress = new CancelOnProgress(cancellation);
                await ExpectCancellation(() => RecordingExport.SaveAsync(session.SourcePath, existing, RecordingQuality.High, width, height, cancellation.Token, progress));
                Require(progress.WasCalled, "active cancellation happened during native encoding");
            }
            Require(File.ReadAllBytes(existing).SequenceEqual(original), "active cancel preserves existing destination");
            Require(!Directory.EnumerateFiles(directory, ".slightshot-*").Any(), "cancel cleans staging files");
            await RecordingExport.SaveAsync(session.SourcePath, existing, RecordingQuality.Compact, width, height, CancellationToken.None);
            Require(new FileInfo(existing).Length > original.Length, "retry replaces destination only after successful completion");
            File.Delete(existing);
            checks.Add("Early and active export cancellation preserved an existing file, removed staging files, and allowed a successful retry.");
        }
        finally { session.Dispose(); }
        Require(!Directory.Exists(temporary), "temporary source directory cleaned");
        await ValidateSessionEndingsAsync(checks);
        checks.Add("Temporary source directory removed after recording/export release their file handles.");
        string oddVideo = await ValidateOddAreaAsync(directory, checks);
        ValidateTemporarySweep(checks);
        await ValidateSessionEndAsync(oddVideo, checks);
        File.WriteAllText(Path.Combine(directory, "recording-validation.json"), JsonSerializer.Serialize(new { platform = "Windows native WPF / MediaTranscoder", source = "Real recording-control HWNDs plus moving synthetic BGRA video. Native display affinity, UI rendering, media encode/decode and lifecycle evidence; not a manual desktop recording or proof of GDI exclusion.", checks }, new JsonSerializerOptions { WriteIndented = true }));
    }
    private static async Task RequireDecodedColorAsync(MediaComposition composition, TimeSpan position, byte[] expected)
    {
        using var thumbnail = await composition.GetThumbnailAsync(position, 160, 90, VideoFramePrecision.NearestFrame);
        var decoder = await Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(thumbnail);
        var pixels = await decoder.GetPixelDataAsync(Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, Windows.Graphics.Imaging.BitmapAlphaMode.Ignore,
            new Windows.Graphics.Imaging.BitmapTransform(), Windows.Graphics.Imaging.ExifOrientationMode.IgnoreExifOrientation,
            Windows.Graphics.Imaging.ColorManagementMode.DoNotColorManage);
        byte[] bytes = pixels.DetachPixelData();
        int center = checked(((int)decoder.PixelHeight / 2 * (int)decoder.PixelWidth + (int)decoder.PixelWidth / 2) * 4);
        for (int channel = 0; channel < 3; channel++)
            Require(Math.Abs(bytes[center + channel] - expected[channel]) < 45, $"decoded frame at {position.TotalSeconds:0.0}s retains channel {channel} after pooled buffer reuse");
    }

    private static async Task ValidateSessionEndingsAsync(List<string> checks)
    {
        // Native cancellation can finish before the final Processed callback.
        // Repeating sessions and disposal exercises those late releases.
        for (int iteration = 0; iteration < 3; iteration++)
        {
            int frames = 0;
            using var session = new RecordingSession(320, 180, bytes => { bytes.AsSpan().Fill(255); Interlocked.Increment(ref frames); });
            var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            session.Started += () => started.TrySetResult();
            Task recording = session.RunAsync();
            await Task.WhenAny(started.Task, recording).WaitAsync(TimeSpan.FromSeconds(30));
            if (recording.IsCompleted) await recording;
            await started.Task.WaitAsync(TimeSpan.FromSeconds(30));
            await Task.Delay(250);
            session.Abort(); session.Abort();
            await ExpectCancellation(() => recording.WaitAsync(TimeSpan.FromSeconds(30)));
            Require(frames > 0, "abort fixture captured native samples");
            session.Dispose(); session.Dispose(); session.Stop(); session.Abort();
            Require(!Directory.Exists(session.DirectoryPath), "repeated abort/dispose cleans the source directory");
        }
        using (var session = new RecordingSession(320, 180, _ => throw new IOException("Expected capture failure.")))
        {
            try { await session.RunAsync().WaitAsync(TimeSpan.FromSeconds(30)); throw new InvalidOperationException("Capture failure was ignored."); }
            catch (Exception error) when (error is not TimeoutException && error.ToString().Contains("Expected capture failure.", StringComparison.Ordinal)) { }
            session.Dispose();
            Require(!Directory.Exists(session.DirectoryPath), "capture failure cleans rented frames and the source directory");
        }
        using (var session = new RecordingSession(320, 180, _ => throw new InvalidOperationException("Pre-start abort captured a frame.")))
        {
            session.Abort();
            await ExpectCancellation(() => session.RunAsync().WaitAsync(TimeSpan.FromSeconds(30)));
        }
        checks.Add("Three native sessions captured then aborted, tolerated repeated Abort/Dispose and late completion, and removed their temporary files. Capture failure and pre-start cancellation completed without a stranded buffer wait.");
    }
    // GDI capture of another process's window: Slightshot excludes its own
    // windows from recordings, so a PowerShell form shows the fixture pattern.
    private static async Task<string> ValidateOddAreaAsync(string directory, List<string> checks)
    {
        const int patternWidth = 801, patternHeight = 451, screenX = 100, screenY = 100;
        byte[] pattern = new byte[patternWidth * patternHeight * 4];
        for (int y = 0; y < patternHeight; y++) for (int x = 0; x < patternWidth; x++)
        {
            // Two-pixel stripes above a three-pixel checkerboard; the last column
            // and row are mid-grey so the cropped edge is visible in evidence.
            byte value = x == patternWidth - 1 || y == patternHeight - 1 ? (byte)128
                : y < patternHeight / 2 ? (byte)(x / 2 % 2 == 0 ? 16 : 240) : (byte)((x / 3 + y / 3) % 2 == 0 ? 40 : 216);
            int i = (y * patternWidth + x) * 4;
            pattern[i] = pattern[i + 1] = pattern[i + 2] = value; pattern[i + 3] = 255;
        }
        string fixture = Path.Combine(Path.GetTempPath(), "Slightshot-OddArea-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(fixture);
        string image = Path.Combine(fixture, "pattern.png"), script = Path.Combine(fixture, "show.ps1");
        using (var stream = File.Create(image))
            OutputService.Encode(BitmapSource.Create(patternWidth, patternHeight, 96, 96, PixelFormats.Bgra32, null, pattern, patternWidth * 4), ImageFormat.Png, 1).Save(stream);
        File.WriteAllText(script, """
            param([string]$Image, [int]$X, [int]$Y)
            Add-Type -AssemblyName System.Windows.Forms, System.Drawing
            Add-Type 'using System; using System.Runtime.InteropServices; public static class Native { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size); }'
            [Native]::SetProcessDPIAware() | Out-Null
            $bitmap = [System.Drawing.Bitmap]::FromFile($Image)
            $form = New-Object System.Windows.Forms.Form
            $form.FormBorderStyle = 'None'; $form.StartPosition = 'Manual'; $form.ShowInTaskbar = $false; $form.TopMost = $true
            $form.Location = New-Object System.Drawing.Point($X, $Y); $form.ClientSize = $bitmap.Size
            $form.BackgroundImage = $bitmap; $form.BackgroundImageLayout = 'None'
            $form.Add_Shown({ $square = 1; [Native]::DwmSetWindowAttribute($form.Handle, 33, [ref]$square, 4) | Out-Null; [Console]::Out.WriteLine('ready'); [Console]::Out.Flush() })
            [System.Windows.Forms.Application]::Run($form)
            """);
        using var host = Process.Start(new ProcessStartInfo("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", "-File", script, image, screenX.ToString(CultureInfo.InvariantCulture), screenY.ToString(CultureInfo.InvariantCulture)])
            { UseShellExecute = false, RedirectStandardOutput = true, CreateNoWindow = true })!;
        try
        {
            string? ready = await host.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(60));
            Require(ready == "ready", "fixture pattern window opened in a separate process");
            SetCursorPos(0, 0); await Task.Delay(750); NativeMethods.DwmFlush();
            var display = ScreenCapture.CaptureAll(false).First(item => screenX >= item.Left && screenY >= item.Top && screenX < item.Left + item.PixelWidth && screenY < item.Top + item.PixelHeight);
            var selection = new RectD((screenX - display.Left) / display.Scale, (screenY - display.Top) / display.Scale, patternWidth / display.Scale, patternHeight / display.Scale);
            RectD region = selection.ToPixels(display.Scale, display.Scale, display.PixelWidth, display.PixelHeight);
            Require(region.Width == patternWidth && region.Height == patternHeight, "fixture selection covers an odd 801×451 pixel area");
            var geometry = RecordingGeometry.Create((int)region.Width, (int)region.Height, (int)region.Width, (int)region.Height);
            Require(geometry == new RecordingGeometry(800, 450, 800, 450), "odd area is cropped to 800×450 instead of resampled");
            int width = geometry.Width, height = geometry.Height, left = display.Left + (int)region.X, top = display.Top + (int)region.Y;
            byte[] truth = new byte[width * height * 4];
            new FormatConvertedBitmap(display.Image, PixelFormats.Bgra32, null, 0).CopyPixels(new Int32Rect((int)region.X, (int)region.Y, width, height), truth, width * 4, 0);
            Require(Difference(truth, pattern, patternWidth, width, height).Mismatched == 0, "desktop shows the fixture pattern pixel for pixel");
            byte[] exact = new byte[truth.Length], legacy = new byte[truth.Length];
            using (var capture = new GdiRecordingCapture(left, top, geometry, false)) capture.Capture(exact);
            using (var capture = new GdiRecordingCapture(left, top, new RecordingGeometry(patternWidth, patternHeight, width, height), false)) capture.Capture(legacy);
            var exactDifference = Difference(exact, truth, width, width, height);
            var legacyDifference = Difference(legacy, truth, width, width, height);
            if (exactDifference.Mismatched != 0)
            {
                foreach (var (name, pixels) in new[] { ("exact", exact), ("truth", truth) })
                {
                    using var stream = File.Create(Path.Combine(directory, $"odd-area-failure-{name}.png"));
                    OutputService.Encode(BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgra32, null, pixels, width * 4), ImageFormat.Png, 1).Save(stream);
                }
                var windows = new List<string>();
                RecordingNative.EnumWindows((window, _) =>
                {
                    if (RecordingNative.IsWindowVisible(window) && RecordingNative.GetWindowRect(window, out var bounds) && bounds.Left < left + width && bounds.Right > left && bounds.Top < top + height && bounds.Bottom > top)
                    {
                        RecordingNative.GetWindowThreadProcessId(window, out uint process);
                        string name; try { name = Process.GetProcessById((int)process).ProcessName; } catch (ArgumentException) { name = "?"; }
                        windows.Add($"{name}#{process} ex=0x{RecordingNative.GetWindowLong(window, -20):X} [{bounds.Left},{bounds.Top},{bounds.Right},{bounds.Bottom}]");
                    }
                    return true;
                }, IntPtr.Zero);
                Require(false, "cropped GDI recording frame equals the desktop pixels exactly: " + Describe(exact, truth, width, height, exactDifference.Mismatched) + "; windows over the area (front first): " + string.Join("; ", windows));
            }
            Require(legacyDifference.Mismatched > width * height / 10, "the previous 801→800 rescale visibly changes this fixture");

            var session = RecordingSession.Create(display, selection, includeCursor: false, nativeResolution: true);
            string video = Path.Combine(directory, "recording-odd-area.mp4");
            try
            {
                Require(session.Width == width && session.Height == height, "odd-area session encodes 800×450");
                var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                session.Started += () => started.TrySetResult();
                Task recording = session.RunAsync();
                await Task.WhenAny(started.Task, recording).WaitAsync(TimeSpan.FromSeconds(30));
                if (recording.IsCompleted) await recording;
                await Task.Delay(1500); session.Stop();
                await recording.WaitAsync(TimeSpan.FromSeconds(30));
                await RecordingExport.SaveAsync(session.SourcePath, video, RecordingQuality.High, width, height, CancellationToken.None);
            }
            finally { session.Dispose(); }
            byte[] decoded = new byte[truth.Length];
            using (var source = await VideoFrameSource.OpenAsync(video))
            {
                Require(source.Width == width && source.Height == height, "exported odd-area MP4 is 800×450");
                (await source.GetFrameAsync(TimeSpan.FromSeconds(0.5))).CopyPixels(decoded, width * 4, 0);
            }
            var decodedDifference = Difference(decoded, truth, width, width, height);
            var legacyEdge = Difference(legacy, truth, width, width, height, fromX: width - 100);
            var decodedEdge = Difference(decoded, truth, width, width, height, fromX: width - 100);
            string measured = string.Create(CultureInfo.InvariantCulture,
                $"mean luma error: exported {decodedDifference.MeanError:0.00} (right 100 columns {decodedEdge.MeanError:0.00}); previous rescale before encoding {legacyDifference.MeanError:0.00} (right 100 columns {legacyEdge.MeanError:0.00}), {legacyDifference.Mismatched} of {width * height} pixels changed");
            Require(decodedDifference.MeanError < legacyDifference.MeanError / 2 && decodedEdge.MeanError < legacyEdge.MeanError / 2, "exported pixels stay closer to the source than the previous rescale did: " + measured);
            SaveOddAreaComparison(Path.Combine(directory, "recording-odd-area-comparison.png"), truth, decoded, legacy, width, decodedDifference.MeanError, legacyDifference.MeanError);
            checks.Add($"Odd 801×451 area of a separate-process fixture window was cropped to 800×450 (last column and row dropped). The raw GDI recording frame matched the desktop exactly; the previous StretchBlt 801→800 changed {legacyDifference.Mismatched} pixels. After H.264 recording and High export, {measured}.");
            return video;
        }
        finally
        {
            if (!host.HasExited) { host.Kill(entireProcessTree: true); await host.WaitForExitAsync(); }
            try { Directory.Delete(fixture, true); } catch (IOException) { }
        }
    }
    private static (int Mismatched, double MeanError) Difference(byte[] actual, byte[] expected, int expectedStride, int width, int height, int fromX = 0)
    {
        int mismatched = 0; double error = 0;
        for (int y = 0; y < height; y++) for (int x = fromX; x < width; x++)
        {
            int a = (y * width + x) * 4, e = (y * expectedStride + x) * 4;
            if (actual[a] != expected[e] || actual[a + 1] != expected[e + 1] || actual[a + 2] != expected[e + 2]) mismatched++;
            error += Math.Abs(Luma(actual, a) - Luma(expected, e));
        }
        return (mismatched, error / ((width - fromX) * height));
    }
    private static string Describe(byte[] actual, byte[] expected, int width, int height, int mismatched)
    {
        for (int index = 0; index < width * height * 4; index += 4)
            if (actual[index] != expected[index] || actual[index + 1] != expected[index + 1] || actual[index + 2] != expected[index + 2])
                return string.Create(CultureInfo.InvariantCulture, $"{mismatched} pixels differ; first at ({index / 4 % width}, {index / 4 / width}) is {actual[index]},{actual[index + 1]},{actual[index + 2]} instead of {expected[index]},{expected[index + 1]},{expected[index + 2]}");
        return "no difference";
    }
    private static double Luma(byte[] pixels, int index) => 0.0722 * pixels[index] + 0.7152 * pixels[index + 1] + 0.2126 * pixels[index + 2];
    private static void SaveOddAreaComparison(string path, byte[] truth, byte[] decoded, byte[] legacy, int width, double decodedError, double legacyError)
    {
        // The right edge crosses the stripe/checker boundary, where a fractional
        // rescale drifts furthest from the source.
        const int size = 40, zoom = 8, panel = size * zoom, margin = 16, label = 44;
        int originX = width - size, originY = 451 / 2 - size / 2;
        var visual = new DrawingVisual();
        using (var drawing = visual.RenderOpen())
        {
            drawing.DrawRectangle(Brushes.White, null, new Rect(0, 0, 3 * panel + 4 * margin, panel + label + 2 * margin));
            var panels = new (byte[] Pixels, string Title)[]
            {
                (truth, "Desktop source (right edge, 8×)"),
                (decoded, string.Create(CultureInfo.InvariantCulture, $"Exported MP4, cropped · error {decodedError:0.0}")),
                (legacy, string.Create(CultureInfo.InvariantCulture, $"Previous 801→800 rescale · error {legacyError:0.0}"))
            };
            for (int index = 0; index < panels.Length; index++)
            {
                byte[] zoomed = new byte[panel * panel * 4];
                for (int y = 0; y < panel; y++) for (int x = 0; x < panel; x++)
                    Array.Copy(panels[index].Pixels, ((originY + y / zoom) * width + originX + x / zoom) * 4, zoomed, (y * panel + x) * 4, 4);
                double x0 = margin + index * (panel + margin);
                drawing.DrawImage(BitmapSource.Create(panel, panel, 96, 96, PixelFormats.Bgra32, null, zoomed, panel * 4), new Rect(x0, margin + label, panel, panel));
                drawing.DrawText(new FormattedText(panels[index].Title, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), 13, Brushes.Black, 1), new Point(x0, margin));
            }
            drawing.DrawText(new FormattedText("Windows CI · fixture window · automated", CultureInfo.InvariantCulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), 11, Brushes.DimGray, 1), new Point(margin, margin + 20));
        }
        var bitmap = new RenderTargetBitmap(3 * panel + 4 * margin, panel + label + 2 * margin, 96, 96, PixelFormats.Pbgra32); bitmap.Render(visual);
        using var stream = File.Create(path); OutputService.Encode(bitmap, ImageFormat.Png, 1).Save(stream);
    }

    private static void ValidateTemporarySweep(List<string> checks)
    {
        string Leftover(bool owner)
        {
            string path = Path.Combine(Path.GetTempPath(), RecordingDirectories.Prefix + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(path);
            File.WriteAllBytes(Path.Combine(path, "source.mp4"), [1, 2, 3]);
            if (owner) File.WriteAllBytes(Path.Combine(path, RecordingDirectories.OwnerFile), []);
            return path;
        }
        string crashed = Leftover(owner: true), legacy = Leftover(owner: false), creating = Leftover(owner: false);
        Directory.SetCreationTimeUtc(legacy, DateTime.UtcNow.AddHours(-2));
        using var live = new RecordingSession(320, 180, _ => { });
        live.Files.Keep();
        var kept = RecordingDirectory.Sweep();
        try
        {
            Require(!Directory.Exists(crashed), "startup sweep removes a directory whose owner exited");
            Require(!Directory.Exists(legacy), "startup sweep removes an old directory from a version without owner locks");
            Require(Directory.Exists(creating), "startup sweep leaves a directory that is still being created");
            Require(Directory.Exists(live.DirectoryPath) && File.Exists(Path.Combine(live.DirectoryPath, RecordingDirectories.OwnerFile)), "startup sweep leaves a live session's directory");
            Require(kept.All(directory => directory.DirectoryPath != live.DirectoryPath), "a kept live session is not adopted by another sweep");
        }
        finally { foreach (var directory in kept) directory.Dispose(); Directory.Delete(creating, true); }
        live.Dispose();
        Require(!Directory.Exists(live.DirectoryPath), "live session still removes its own directory");
        checks.Add("Startup sweep deleted a crashed session (owner lock released) and an old unlocked directory, and left a directory still being created and a live, locked session in place.");
    }

    private static async Task ValidateSessionEndAsync(string video, List<string> checks)
    {
        var settings = new Settings();
        var coordinator = new RecordingCoordinator(settings);
        var display = ScreenCapture.UnderPointer(ScreenCapture.CaptureAll(false));
        coordinator.Begin(display, new RectD(40, 40, 320, 180));
        Require(coordinator.IsBusy, "coordinator started a native recording");
        var panel = Application.Current.Windows.OfType<RecordingPanel>().Single();
        Require(BlockReason(panel) == "An unsaved recording is open in Slightshot.", "recording HUD registers a Windows shutdown block reason");
        string recordingDirectory = Directory.EnumerateDirectories(Path.GetTempPath(), RecordingDirectories.Prefix + "*")
            .Single(path =>
            {
                try { using var probe = File.Open(Path.Combine(path, RecordingDirectories.OwnerFile), FileMode.Open, FileAccess.Read, FileShare.ReadWrite); return false; }
                catch (FileNotFoundException) { return false; }
                catch (IOException) { return true; }
            });
        await Task.Delay(1000);
        Require(coordinator.KeepForSessionEnd(), "session end during a recording asks Windows to cancel");
        Require(File.Exists(Path.Combine(recordingDirectory, RecordingDirectories.KeepFile)), "session end keeps the recording for the next launch");
        var editor = await WaitForAsync(() => Application.Current.Windows.OfType<VideoEditorWindow>().SingleOrDefault(), "session end stops the recording and opens the editor");
        Require(BlockReason(editor) == "An unsaved recording is open in Slightshot.", "editor registers a Windows shutdown block reason");
        Require(coordinator.KeepForSessionEnd(), "session end with the editor open asks Windows to cancel");
        Require(RecordingDirectory.Sweep().Count == 0 && Directory.Exists(recordingDirectory), "a kept recording is not swept while its session is alive");
        await coordinator.ShutdownAsync();
        Require(!coordinator.IsBusy && !Directory.Exists(recordingDirectory), "quitting Slightshot removes the recording directory");

        string Kept()
        {
            string path = Path.Combine(Path.GetTempPath(), RecordingDirectories.Prefix + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(path);
            File.Copy(video, Path.Combine(path, "source.mp4"));
            File.WriteAllBytes(Path.Combine(path, RecordingDirectories.OwnerFile), []);
            File.WriteAllBytes(Path.Combine(path, RecordingDirectories.KeepFile), []);
            return path;
        }
        string discarded = Kept();
        var declining = new RecordingCoordinator(settings);
        int asked = 0;
        declining.Recover(recording => { asked++; return false; });
        await WaitForAsync(() => declining.IsBusy ? null : (object?)true, "declined recovery finishes");
        Require(asked == 1 && !Directory.Exists(discarded), "declining the next-launch offer deletes the kept recording");

        string reopened = Kept();
        var recovering = new RecordingCoordinator(settings);
        string? offered = null;
        recovering.Recover(recording => { offered = recording.DirectoryPath; return true; });
        editor = await WaitForAsync(() => Application.Current.Windows.OfType<VideoEditorWindow>().SingleOrDefault(), "accepted recovery opens the editor");
        Require(offered == reopened && recovering.IsBusy, "next launch offers the kept recording and blocks new captures while editing");
        Require(RecordingDirectory.Sweep().Count == 0 && Directory.Exists(reopened), "a reopened recording is locked against other sweeps");
        editor.CloseFixture();
        await WaitForAsync(() => recovering.IsBusy ? null : (object?)true, "closing the recovered editor finishes");
        Require(!Directory.Exists(reopened), "closing the recovered editor removes its directory");
        checks.Add("Session end during a real recording returned cancel, wrote the keep marker, stopped and finalized the MP4 and opened the editor; the HUD and editor HWNDs registered the shutdown block reason. A live kept session was never swept and Quit removed it. At the next launch a kept recording from an ended session was offered: No deleted it, Yes reopened it in the editor under a fresh owner lock, and closing the editor removed it.");
    }
    private static string? BlockReason(Window window)
    {
        IntPtr handle = new WindowInteropHelper(window).Handle;
        uint length = 0;
        if (!RecordingNative.ShutdownBlockReasonQuery(handle, null, ref length) || length == 0) return null;
        char[] reason = new char[length];
        return RecordingNative.ShutdownBlockReasonQuery(handle, reason, ref length) ? new string(reason, 0, (int)length).TrimEnd('\0') : null;
    }
    private static async Task<T> WaitForAsync<T>(Func<T?> probe, string check) where T : class
    {
        var watch = Stopwatch.StartNew();
        while (watch.Elapsed < TimeSpan.FromSeconds(30))
        {
            if (probe() is { } value) return value;
            await Task.Delay(100);
        }
        throw new InvalidOperationException("Windows recording smoke test failed: " + check);
    }
    private static async Task ValidateControlsAsync(string directory, List<string> checks)
    {
        var image = new WriteableBitmap(800, 520, 96, 96, PixelFormats.Pbgra32, null); image.Freeze();
        var display = new CapturedDisplay(image, 0, 0, 800, 520, 1);
        foreach (double scale in new[] { 1.0, 2.0 })
        {
            var monitor = new CapturedDisplay(image, -800, 40, 800, 520, scale);
            var selection = new RectD(20, 30, 200, 120);
            var outline = new RecordingOutline(monitor, selection);
            IntPtr region = RecordingNative.CreateRectRgn(0, 0, 0, 0);
            try
            {
                outline.Show();
                await outline.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.Loaded);
                IntPtr handle = new WindowInteropHelper(outline).Handle;
                int styles = RecordingNative.GetWindowLong(handle, -20);
                Require(!outline.AllowsTransparency && (styles & 0x80000) == 0, "boundary avoids layered-window affinity conflict");
                Require((styles & 0x08000020) == 0x08000020, "boundary is passive and does not activate");
                RequireExcluded(outline, "real recording boundary");
                Require(RecordingNative.GetWindowRect(handle, out var bounds), "boundary has native bounds");
                var expected = selection.ToPixels(scale, scale, monitor.PixelWidth, monitor.PixelHeight);
                Require(bounds.Left == monitor.Left + (int)expected.X && bounds.Top == monitor.Top + (int)expected.Y
                    && bounds.Right - bounds.Left == (int)expected.Width && bounds.Bottom - bounds.Top == (int)expected.Height, "boundary matches exact capture rectangle at display scale " + scale);
                Require(RecordingNative.GetWindowRgn(handle, region) != 0, "boundary has a native window region");
                int width = bounds.Right - bounds.Left, height = bounds.Bottom - bounds.Top;
                Require(RecordingNative.PtInRegion(region, 0, height / 2) && RecordingNative.PtInRegion(region, width - 1, height / 2)
                    && RecordingNative.PtInRegion(region, width / 2, 0) && RecordingNative.PtInRegion(region, width / 2, height - 1), "all four recording edges remain visible");
                Require(!RecordingNative.PtInRegion(region, width / 2, height / 2), "boundary center is a native hole and cannot intercept source content");
            }
            finally { outline.Close(); NativeMethods.DeleteObject(region); }
        }
        checks.Add("Real recording boundary HWNDs at 100%/200% display scale match the exact capture pixels, including negative monitor origins; all four native edges exist, the center is hollow, activation/layered styles are absent, and WDA_EXCLUDEFROMCAPTURE is retained.");
        bool stopped = false;
        var panel = new RecordingPanel(display, new RectD(100, 100, 560, 300), () => stopped = true);
        try
        {
            panel.Show();
            await panel.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.Loaded);
            Require(!panel.AllowsTransparency, "HUD avoids per-pixel layered-window affinity conflict on Windows 10");
            IntPtr handle = new WindowInteropHelper(panel).Handle;
            Require((RecordingNative.GetWindowLong(handle, -20) & 0x80000) == 0, "HUD HWND is not WS_EX_LAYERED");
            RequireExcluded(panel, "real recording HUD");
            var stop = Descendants<ToolbarButton>((DependencyObject)panel.Content).Single();
            Require(!stop.IsEnabled, "Stop waits for native recording startup");
            panel.Started(() => TimeSpan.FromSeconds(123));
            Require(stop.IsEnabled, "Stop becomes available after recording startup");
            Require(Descendants<TextBlock>((DependencyObject)panel.Content).Any(text => text.Text == "02:03"), "HUD displays elapsed recording time");
            SaveVisual(panel, 112, Path.Combine(directory, "recording-hud.png"));
            stop.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Require(stopped, "real HUD Stop invokes recording stop callback");
        }
        finally { panel.Close(); }
        checks.Add("Real recording HUD HWND is opaque (no WS_EX_LAYERED), accepts/readbacks WDA_EXCLUDEFROMCAPTURE, enables Stop after startup and renders its timer/Stop fixture.");
        foreach (bool dark in new[] { false, true })
        {
            var save = new RecordingSaveWindow(new Settings { SaveDirectory = directory, RecordingQuality = RecordingQuality.Balanced }, 1600, 900, null, dark);
            try
            {
                save.Show();
                await save.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.Loaded);
                RequireExcluded(save, "real recording save dialog");
                var slider = Descendants<Slider>((DependencyObject)save.Content).Single();
                Require(save.Quality == RecordingQuality.Balanced, "save dialog restores selected quality");
                foreach (var quality in Enum.GetValues<RecordingQuality>())
                {
                    slider.Value = (int)quality;
                    Require(save.Quality == quality, "save-time slider chooses " + quality.Title());
                    Require(Descendants<TextBlock>((DependencyObject)save.Content).Any(text => text.Text == quality.Detail(1600, 900)), "save dialog updates quality details");
                    SaveVisual(save, 440, Path.Combine(directory, $"recording-save-{(dark ? "dark" : "light")}-{quality.ToString().ToLowerInvariant()}.png"));
                }
                Require(!save.Destination.Contains("Screenshot", StringComparison.Ordinal), "save dialog proposes recording file name");
            }
            finally { save.Close(); }
        }
        var progress = new RecordingProgressWindow(() => { });
        try { progress.Show(); RequireExcluded(progress, "real recording progress dialog"); }
        finally { progress.Close(); }
        checks.Add("Real save/progress HWNDs accept/readback display affinity. Save dialog renders light/dark fixtures, restores Balanced and updates details for all three slider choices.");
    }
    private static void RequireExcluded(Window window, string title)
    {
        Require(RecordingNative.GetWindowDisplayAffinity(new WindowInteropHelper(window).Handle, out uint affinity) && affinity == 0x11, title + " accepts and retains WDA_EXCLUDEFROMCAPTURE");
    }
    private static IEnumerable<T> Descendants<T>(DependencyObject root) where T : DependencyObject
    {
        if (root is T match) yield return match;
        for (int index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
            foreach (var child in Descendants<T>(VisualTreeHelper.GetChild(root, index))) yield return child;
    }
    private static void SaveVisual(Window window, int width, string path)
    {
        var element = (FrameworkElement)window.Content;
        element.Measure(new Size(width, double.PositiveInfinity)); int height = Math.Max(1, (int)Math.Ceiling(element.DesiredSize.Height));
        element.Arrange(new Rect(0, 0, width, height)); element.UpdateLayout();
        // Window.Background is painted by its HWND rather than the content
        // StackPanel. Include it so rendered evidence matches the actual theme.
        var background = new DrawingVisual();
        using (var drawing = background.RenderOpen())
        {
            double radius = window is RecordingPanel ? 9 : 0;
            drawing.DrawRoundedRectangle(window.Background, null, new Rect(0, 0, width, height), radius, radius);
        }
        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32); bitmap.Render(background); bitmap.Render(element);
        using var stream = File.Create(path); OutputService.Encode(bitmap, ImageFormat.Png, 1).Save(stream);
    }
    private sealed class CancelOnProgress(CancellationTokenSource cancellation) : IProgress<double>
    {
        internal bool WasCalled { get; private set; }
        public void Report(double value) { WasCalled = true; cancellation.Cancel(); }
    }
    private static async Task ExpectCancellation(Func<Task> operation)
    {
        try { await operation(); throw new InvalidOperationException("Native media operation ignored cancellation."); }
        catch (OperationCanceledException) { }
    }
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    private static void Require(bool condition, string check) { if (!condition) throw new InvalidOperationException("Windows recording smoke test failed: " + check); }
}
