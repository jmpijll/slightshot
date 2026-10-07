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
        byte[] Pixels()
        {
            var bytes = new byte[width * height * 4]; int number = Interlocked.Increment(ref frame);
            for (int y = 0; y < height; y++) for (int x = 0; x < width; x++)
            {
                int i = (y * width + x) * 4;
                bytes[i] = (byte)((x * 13 + y * 7 + number * 31) % 256);
                bytes[i + 1] = (byte)((x * 5 + y * 19 + number * 11) % 256);
                bytes[i + 2] = (byte)((x * 17 + y * 3 + number * 23) % 256); bytes[i + 3] = 255;
            }
            return bytes;
        }
        var checks = new List<string>();
        await ValidateControlsAsync(directory, checks);
        var session = new RecordingSession(width, height, Pixels);
        string temporary = session.DirectoryPath;
        try
        {
            var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            session.Started += () => started.TrySetResult();
            Task recording = session.RunAsync();
            await Task.WhenAny(started.Task, recording).WaitAsync(TimeSpan.FromSeconds(30));
            if (recording.IsCompleted) await recording;
            await started.Task.WaitAsync(TimeSpan.FromSeconds(30));
            await Task.Delay(1800); session.Stop();
            await recording.WaitAsync(TimeSpan.FromSeconds(30));
            Require(frame >= 5, "live frame provider was sampled repeatedly");
            var source = await StorageFile.GetFileFromPathAsync(session.SourcePath);
            var metadata = await source.Properties.GetVideoPropertiesAsync();
            Require(metadata.Width == width && metadata.Height == height && metadata.Duration.TotalSeconds > 0.1, "source contains playable H.264 video at selected dimensions");
            checks.Add("Native BGRA frames encoded to a playable H.264 MP4 source; Stop finalized the file.");
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
        checks.Add("Temporary source directory removed after recording/export release their file handles.");
        File.WriteAllText(Path.Combine(directory, "recording-validation.json"), JsonSerializer.Serialize(new { platform = "Windows native WPF / MediaTranscoder", source = "Real recording-control HWNDs plus moving synthetic BGRA video. Native display affinity, UI rendering, media encode/decode and lifecycle evidence; not a manual desktop recording or proof of GDI exclusion.", checks }, new JsonSerializerOptions { WriteIndented = true }));
    }
    private static async Task ValidateControlsAsync(string directory, List<string> checks)
    {
        var image = new WriteableBitmap(800, 520, 96, 96, PixelFormats.Pbgra32, null); image.Freeze();
        var display = new CapturedDisplay(image, 0, 0, 800, 520, 1);
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
            SaveVisual((FrameworkElement)panel.Content, 112, Path.Combine(directory, "recording-hud.png"));
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
                    SaveVisual((FrameworkElement)save.Content, 440, Path.Combine(directory, $"recording-save-{(dark ? "dark" : "light")}-{quality.ToString().ToLowerInvariant()}.png"));
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
    private static void SaveVisual(FrameworkElement element, int width, string path)
    {
        element.Measure(new Size(width, double.PositiveInfinity)); int height = Math.Max(1, (int)Math.Ceiling(element.DesiredSize.Height));
        element.Arrange(new Rect(0, 0, width, height)); element.UpdateLayout();
        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32); bitmap.Render(element);
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
    private static void Require(bool condition, string check) { if (!condition) throw new InvalidOperationException("Windows recording smoke test failed: " + check); }
}
