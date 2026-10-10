using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Media.Core;
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage;
using Windows.Foundation;
using Slightshot.Core;

namespace Slightshot;

// Windows' media pipeline requests one limited-range BT.709 NV12 frame at a
// time. One BGRA capture scratch is converted before submission; only NV12
// sample storage stays rented until Processed. Capture has no frame backlog.
internal sealed class RecordingSession : IDisposable
{
    private readonly Action<byte[]> captureFrame;
    private IDisposable? captureResource;
    private readonly RecordingFrameBuffers frameBuffers;
    private byte[]? capturePixels;
    private readonly object lifetime = new();
    private TaskCompletionSource? callbacksDrained;
    private int activeCallbacks;
    private bool acceptingSamples = true, disposed;
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

    internal RecordingSession(int width, int height, Action<byte[]> captureFrame, IDisposable? captureResource = null)
    {
        if (width <= 0 || height <= 0 || (width & 1) != 0 || (height & 1) != 0) throw new ArgumentOutOfRangeException(nameof(width));
        Width = width; Height = height; this.captureFrame = captureFrame; this.captureResource = captureResource;
        int area = checked(width * height);
        capturePixels = new byte[checked(area * 4)];
        frameBuffers = new(checked(area + area / 2));
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

    internal Task RunAsync()
    {
        lock (lifetime) { ObjectDisposedException.ThrowIf(disposed, this); return completion ??= Task.Run(EncodeAsync); }
    }
    internal void Stop()
    {
        lock (lifetime) { if (disposed) return; Interlocked.Exchange(ref stopping, 1); stopSignal.Cancel(); }
    }
    internal void Abort()
    {
        lock (lifetime) { if (disposed) return; Stop(); abortSignal.Cancel(); }
    }

    private async Task EncodeAsync()
    {
        var properties = RecordingExport.FrameProperties(Width, Height, 30);
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
            if (captureError != null) throw captureError;
            if (frames == 0) throw new InvalidOperationException("No video frames were recorded. Try recording for a little longer.");
        }
        catch (Exception) when (captureError != null)
        {
            throw new InvalidOperationException("The recording stopped because the screen could no longer be captured.", captureError);
        }
        finally
        {
            clock.Stop(); Stop();
            Task drained;
            lock (lifetime)
            {
                acceptingSamples = false;
                drained = activeCallbacks == 0 ? Task.CompletedTask : (callbacksDrained = new(TaskCreationOptions.RunContinuationsAsynchronously)).Task;
            }
            source.Starting -= SourceStarting; source.SampleRequested -= SampleRequested;
            // Cancellation can complete the native operation before a deferral
            // finishes. Stop wakes pacing, semaphore and buffer waits; account
            // for every admitted callback before releasing capture resources.
            await drained;
            frameBuffers.Dispose();
            capturePixels = null;
            Interlocked.Exchange(ref captureResource, null)?.Dispose();
        }
    }

    private void SourceStarting(MediaStreamSource sender, MediaStreamSourceStartingEventArgs args)
    {
        lock (lifetime)
        {
            if (!acceptingSamples || stopping != 0) return;
            args.Request.SetActualStartPosition(TimeSpan.Zero);
            clock.Start(); Started?.Invoke();
        }
    }

    private async void SampleRequested(MediaStreamSource sender, MediaStreamSourceSampleRequestedEventArgs args)
    {
        var deferral = args.Request.GetDeferral();
        bool entered = false, admitted = false;
        RecordingFrame? frame = null;
        MediaStreamSample? sample = null;
        TypedEventHandler<MediaStreamSample, object>? processed = null;
        try
        {
            lock (lifetime)
            {
                if (!acceptingSamples) return;
                activeCallbacks++; admitted = true;
            }
            await samples.WaitAsync(stopSignal.Token); entered = true;
            if (Volatile.Read(ref stopping) != 0) return;
            TimeSpan due = TimeSpan.FromTicks(nextTimestamp) - clock.Elapsed;
            if (due > TimeSpan.Zero) await Task.Delay(due, stopSignal.Token);
            if (Volatile.Read(ref stopping) != 0) return;
            frame = await frameBuffers.RentAsync(stopSignal.Token);
            // The samples semaphore serializes this scratch. Native samples
            // retain their separate NV12 leases, never the mutable BGRA input.
            var captured = capturePixels ?? throw new ObjectDisposedException(nameof(RecordingSession));
            captureFrame(captured);
            if (Volatile.Read(ref stopping) != 0) return;
            BgraToNv12.Convert(captured, frame.Pixels, Width, Height);
            if (Volatile.Read(ref stopping) != 0) return;
            long timestamp = frames == 0 ? 0 : Math.Max(nextTimestamp, clock.Elapsed.Ticks);
            sample = MediaStreamSample.CreateFromBuffer(frame.Pixels.AsBuffer(), TimeSpan.FromTicks(timestamp));
            sample.Duration = TimeSpan.FromTicks(TimeSpan.TicksPerSecond / 30);
            sample.KeyFrame = true;
            var submittedFrame = frame;
            processed = (completed, _) =>
            {
                completed.Processed -= processed;
                submittedFrame.Dispose();
            };
            sample.Processed += processed;
            args.Request.Sample = sample;
            // Only Processed may return a submitted frame. A late callback after
            // shutdown drops its storage instead of reopening the closed pool.
            frame = null;
            frames++; nextTimestamp = timestamp + sample.Duration.Ticks;
        }
        catch (OperationCanceledException) { /* Null sample finishes a normal Stop. */ }
        catch (Exception error)
        {
            captureError = error; Stop(); sender.NotifyError(MediaStreamSourceErrorStatus.Other);
        }
        finally
        {
            if (frame != null)
            {
                if (sample != null && processed != null) sample.Processed -= processed;
                frame.Dispose();
            }
            if (entered) samples.Release();
            try { deferral.Complete(); }
            finally
            {
                if (admitted) lock (lifetime) { if (--activeCallbacks == 0) callbacksDrained?.TrySetResult(); }
            }
        }
    }

    public void Dispose()
    {
        // Only call after RunAsync has completed: neither media nor capture keeps
        // a handle to the source file when its temporary directory is removed.
        lock (lifetime)
        {
            if (disposed) return;
            if (completion is { IsCompleted: false }) throw new InvalidOperationException("Wait for recording completion before disposing the session.");
            disposed = true; acceptingSamples = false;
            frameBuffers.Dispose();
            capturePixels = null;
            Interlocked.Exchange(ref captureResource, null)?.Dispose();
            stopSignal.Dispose(); abortSignal.Dispose(); samples.Dispose();
        }
        try { Directory.Delete(DirectoryPath, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}
