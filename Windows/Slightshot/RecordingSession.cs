using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Media.Core;
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage;
using Slightshot.Core;

namespace Slightshot;

// Windows' media pipeline requests one BGRA frame at a time and encodes it to
// H.264. Capture is paced against a monotonic clock, with no frame backlog.
internal sealed class RecordingSession : IDisposable
{
    private readonly Func<byte[]> captureFrame;
    private readonly IDisposable? captureResource;
    private readonly CancellationTokenSource stopSignal = new();
    private readonly CancellationTokenSource abortSignal = new();
    private readonly SemaphoreSlim samples = new(1, 1);
    private readonly Stopwatch clock = new();
    private Exception? captureError;
    private long nextTimestamp;
    private int frames;
    private int stopping;
    private Task? completion;
    internal string DirectoryPath { get; } = Path.Combine(Path.GetTempPath(), "Slightshot-Recording-" + Guid.NewGuid().ToString("N"));
    internal string SourcePath => Path.Combine(DirectoryPath, "source.mp4");
    internal int Width { get; }
    internal int Height { get; }
    internal TimeSpan Duration => clock.Elapsed;
    internal event Action? Started;

    internal RecordingSession(int width, int height, Func<byte[]> captureFrame, IDisposable? captureResource = null)
    {
        Width = width; Height = height; this.captureFrame = captureFrame; this.captureResource = captureResource;
        Directory.CreateDirectory(DirectoryPath);
    }

    internal static RecordingSession Create(CapturedDisplay display, RectD selection, bool includeCursor, bool nativeResolution)
    {
        RectD region = selection.ToPixels(display.Scale, display.Scale, display.PixelWidth, display.PixelHeight);
        var size = RecordingQuality.High.Dimensions(nativeResolution ? (int)region.Width : (int)Math.Ceiling(selection.Width), nativeResolution ? (int)region.Height : (int)Math.Ceiling(selection.Height));
        var capture = new GdiRecordingCapture(display.Left + (int)region.X, display.Top + (int)region.Y, (int)region.Width, (int)region.Height, size.Width, size.Height, includeCursor);
        try { return new(size.Width, size.Height, capture.Capture, capture); }
        catch { capture.Dispose(); throw; }
    }

    internal Task RunAsync() => completion ??= Task.Run(EncodeAsync);
    internal void Stop() { Interlocked.Exchange(ref stopping, 1); stopSignal.Cancel(); }
    internal void Abort() { Stop(); abortSignal.Cancel(); }

    private async Task EncodeAsync()
    {
        var properties = VideoEncodingProperties.CreateUncompressed(MediaEncodingSubtypes.Bgra8, (uint)Width, (uint)Height);
        properties.FrameRate.Numerator = 30; properties.FrameRate.Denominator = 1;
        properties.PixelAspectRatio.Numerator = properties.PixelAspectRatio.Denominator = 1;
        var source = new MediaStreamSource(new VideoStreamDescriptor(properties)) { BufferTime = TimeSpan.Zero, CanSeek = false, IsLive = true };
        source.Starting += SourceStarting;
        source.SampleRequested += SampleRequested;
        try
        {
            var folder = await StorageFolder.GetFolderFromPathAsync(DirectoryPath).AsTask(abortSignal.Token);
            var file = await folder.CreateFileAsync("source.mp4", CreationCollisionOption.FailIfExists).AsTask(abortSignal.Token);
            using var stream = await file.OpenAsync(FileAccessMode.ReadWrite).AsTask(abortSignal.Token);
            var transcoder = new MediaTranscoder { HardwareAccelerationEnabled = true, AlwaysReencode = true };
            var prepared = await transcoder.PrepareMediaStreamSourceTranscodeAsync(source, stream, RecordingExport.Profile(RecordingQuality.High, Width, Height)).AsTask(abortSignal.Token);
            if (!prepared.CanTranscode) throw new InvalidOperationException($"Windows could not start the video encoder ({prepared.FailureReason}).");
            await prepared.TranscodeAsync().AsTask(abortSignal.Token);
            if (captureError != null) throw new InvalidOperationException("The recording stopped because the screen could no longer be captured.", captureError);
            if (frames == 0) throw new InvalidOperationException("No video frames were recorded. Try recording for a little longer.");
        }
        finally
        {
            clock.Stop(); Stop();
            source.Starting -= SourceStarting; source.SampleRequested -= SampleRequested;
            // A cancelled native transcode may leave its last deferral running.
            // Wait for it before releasing the shared screen DC and DIB.
            await samples.WaitAsync();
            try { captureResource?.Dispose(); }
            finally { samples.Release(); }
        }
    }

    private void SourceStarting(MediaStreamSource sender, MediaStreamSourceStartingEventArgs args)
    {
        args.Request.SetActualStartPosition(TimeSpan.Zero);
        clock.Start(); Started?.Invoke();
    }

    private async void SampleRequested(MediaStreamSource sender, MediaStreamSourceSampleRequestedEventArgs args)
    {
        var deferral = args.Request.GetDeferral();
        bool entered = false;
        try
        {
            await samples.WaitAsync(abortSignal.Token); entered = true;
            if (Volatile.Read(ref stopping) != 0) return;
            TimeSpan due = TimeSpan.FromTicks(nextTimestamp) - clock.Elapsed;
            if (due > TimeSpan.Zero) await Task.Delay(due, stopSignal.Token);
            if (Volatile.Read(ref stopping) != 0) return;
            byte[] bytes = captureFrame();
            if (bytes.Length != checked(Width * Height * 4)) throw new InvalidOperationException("The recording frame has an unexpected size.");
            long timestamp = frames == 0 ? 0 : Math.Max(nextTimestamp, clock.Elapsed.Ticks);
            var sample = MediaStreamSample.CreateFromBuffer(bytes.AsBuffer(), TimeSpan.FromTicks(timestamp));
            sample.Duration = TimeSpan.FromTicks(TimeSpan.TicksPerSecond / 30);
            sample.KeyFrame = true;
            args.Request.Sample = sample;
            frames++; nextTimestamp = timestamp + sample.Duration.Ticks;
        }
        catch (OperationCanceledException) { /* Null sample finishes a normal Stop. */ }
        catch (Exception error)
        {
            captureError = error; Stop(); sender.NotifyError(MediaStreamSourceErrorStatus.Other);
        }
        finally { if (entered) samples.Release(); deferral.Complete(); }
    }

    public void Dispose()
    {
        // Only call after RunAsync has completed: neither media nor capture keeps
        // a handle to the source file when its temporary directory is removed.
        captureResource?.Dispose();
        stopSignal.Dispose(); abortSignal.Dispose(); samples.Dispose();
        try { Directory.Delete(DirectoryPath, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}
