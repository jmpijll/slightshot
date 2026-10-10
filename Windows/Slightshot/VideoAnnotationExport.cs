using System.IO;
using System.Diagnostics;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Foundation;
using Windows.Media.Core;
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage;
using Slightshot.Core;

namespace Slightshot;

internal static class VideoAnnotationExport
{
    internal static async Task SaveAsync(string source, string destination, RecordingQuality quality, int width, int height,
        IReadOnlyList<TimedAnnotation> annotations, CancellationToken cancellation, IProgress<double>? progress = null, VideoExportMetrics? metrics = null)
    {
        if (annotations.Count == 0)
        {
            await RecordingExport.SaveAsync(source, destination, quality, width, height, cancellation, progress);
            return;
        }
        string staging = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(destination))!, ".slightshot-" + Guid.NewGuid().ToString("N") + ".mp4");
        try
        {
            cancellation.ThrowIfCancellationRequested();
            metrics?.RecordMemory("beforeMetadata");
            var input = await StorageFile.GetFileFromPathAsync(source).AsTask(cancellation);
            var metadata = await input.Properties.GetVideoPropertiesAsync().AsTask(cancellation);
            int sourceWidth = checked((int)metadata.Width), sourceHeight = checked((int)metadata.Height);
            TimeSpan duration = metadata.Duration;
            if (sourceWidth <= 0 || sourceHeight <= 0 || duration <= TimeSpan.Zero) throw new InvalidOperationException("This recording has no playable video frames.");
            metrics?.RecordMemory("metadataReady");
            using var sequential = await VideoSequentialDecoder.OpenAsync(source, sourceWidth, sourceHeight);
            metrics?.RecordMemory("sequentialReaderReady");
            using var renderer = new VideoRenderWorker();
            using var frames = new RecordingFrameBuffers(checked(sourceWidth * sourceHeight * 4));
            using var samples = new SemaphoreSlim(1, 1);
            using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
            int active = 0; bool accepting = true;
            object lifetime = new();
            TaskCompletionSource drained = new(TaskCreationOptions.RunContinuationsAsynchronously);
            Exception? sampleError = null;
            long nextFrame = 0;
            int rate = quality.FramesPerSecond();
            var properties = RecordingExport.FrameProperties(sourceWidth, sourceHeight, rate);
            var media = new MediaStreamSource(new VideoStreamDescriptor(properties)) { Duration = duration, CanSeek = false, BufferTime = TimeSpan.Zero };
            void Starting(MediaStreamSource _, MediaStreamSourceStartingEventArgs args) => args.Request.SetActualStartPosition(TimeSpan.Zero);
            async void SampleRequested(MediaStreamSource sender, MediaStreamSourceSampleRequestedEventArgs args)
            {
                var deferral = args.Request.GetDeferral();
                bool admitted = false, entered = false;
                RecordingFrame? frame = null;
                MediaStreamSample? sample = null;
                TypedEventHandler<MediaStreamSample, object>? processed = null;
                try
                {
                    lock (lifetime) { if (!accepting) return; active++; admitted = true; }
                    await samples.WaitAsync(stop.Token); entered = true;
                    var position = TimeSpan.FromTicks(nextFrame * TimeSpan.TicksPerSecond / rate);
                    if (position >= duration) return;
                    long measured = Stopwatch.GetTimestamp();
                    frame = await frames.RentAsync(stop.Token);
                    metrics?.AddBufferWait(Stopwatch.GetElapsedTime(measured).TotalMilliseconds);
                    measured = Stopwatch.GetTimestamp();
                    await sequential.GetFrameAsync(position, frame.Pixels, stop.Token);
                    metrics?.AddDecode(Stopwatch.GetElapsedTime(measured).TotalMilliseconds);
                    if (nextFrame == 0) metrics?.RecordMemory("firstFrameDecoded");
                    measured = Stopwatch.GetTimestamp();
                    await renderer.ComposeAsync(frame.Pixels, sourceWidth, sourceHeight, position, annotations, stop.Token);
                    metrics?.AddRender(Stopwatch.GetElapsedTime(measured).TotalMilliseconds);
                    stop.Token.ThrowIfCancellationRequested();
                    sample = MediaStreamSample.CreateFromBuffer(frame.Pixels.AsBuffer(), position);
                    sample.Duration = TimeSpan.FromTicks(Math.Min(TimeSpan.TicksPerSecond / rate, duration.Ticks - position.Ticks));
                    sample.KeyFrame = true;
                    var submitted = frame;
                    processed = (completed, _) => { completed.Processed -= processed; submitted.Dispose(); };
                    sample.Processed += processed;
                    args.Request.Sample = sample; frame = null; nextFrame++; metrics?.AddSubmittedFrame();
                    if (nextFrame is 1 or 15 or 30) metrics?.RecordMemory("submittedFrame" + nextFrame);
                }
                catch (OperationCanceledException) { }
                catch (Exception error) { sampleError = error; sender.NotifyError(MediaStreamSourceErrorStatus.Other); }
                finally
                {
                    if (frame != null)
                    {
                        if (sample != null && processed != null) sample.Processed -= processed;
                        frame.Dispose();
                    }
                    if (entered) samples.Release();
                    try { deferral.Complete(); }
                    finally { if (admitted) lock (lifetime) { if (--active == 0 && !accepting) drained.TrySetResult(); } }
                }
            }
            media.Starting += Starting; media.SampleRequested += SampleRequested;
            try
            {
                var folder = await StorageFolder.GetFolderFromPathAsync(Path.GetDirectoryName(staging)!).AsTask(cancellation);
                var file = await folder.CreateFileAsync(Path.GetFileName(staging), CreationCollisionOption.FailIfExists).AsTask(cancellation);
                using var output = await file.OpenAsync(FileAccessMode.ReadWrite).AsTask(cancellation);
                var transcoder = new MediaTranscoder { HardwareAccelerationEnabled = true, AlwaysReencode = true };
                metrics?.RecordMemory("beforeTranscoderPrepare");
                var prepared = await transcoder.PrepareMediaStreamSourceTranscodeAsync(media, output, RecordingExport.Profile(quality, width, height)).AsTask(cancellation);
                metrics?.RecordMemory("transcoderPrepared");
                if (!prepared.CanTranscode) throw new InvalidOperationException($"Windows could not export the edited recording ({prepared.FailureReason}).");
                await prepared.TranscodeAsync().AsTask(cancellation, progress);
                metrics?.RecordMemory("transcodeCompleted");
                if (sampleError != null) throw new InvalidOperationException("A video frame could not be rendered.", sampleError);
                if (nextFrame == 0) throw new InvalidOperationException("No edited frames were exported.");
            }
            finally
            {
                lock (lifetime) { accepting = false; if (active == 0) drained.TrySetResult(); }
                stop.Cancel(); media.Starting -= Starting; media.SampleRequested -= SampleRequested;
                await drained.Task;
                metrics?.RecordMemory("sampleCallbacksDrained");
            }
            cancellation.ThrowIfCancellationRequested();
            if (File.Exists(destination)) File.Replace(staging, destination, null);
            else File.Move(staging, destination);
        }
        finally { try { File.Delete(staging); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
    }
}

internal sealed class VideoExportMetrics
{
    private int frames;
    private readonly List<VideoExportMemorySnapshot> memory = [];
    internal IReadOnlyList<VideoExportMemorySnapshot> MemorySnapshots { get { lock (memory) return memory.ToArray(); } }
    internal void RecordMemory(string stage)
    {
        using var process = Process.GetCurrentProcess(); process.Refresh(); var heap = GC.GetGCMemoryInfo();
        var snapshot = new VideoExportMemorySnapshot(stage, Frames, process.PrivateMemorySize64 / 1048576.0, process.WorkingSet64 / 1048576.0,
            GC.GetTotalMemory(false) / 1048576.0, heap.HeapSizeBytes / 1048576.0, heap.TotalCommittedBytes / 1048576.0, GC.GetTotalAllocatedBytes(false) / 1048576.0,
            GC.CollectionCount(0), GC.CollectionCount(1), GC.CollectionCount(2));
        lock (memory) memory.Add(snapshot);
    }
    internal int Frames => Volatile.Read(ref frames);
    internal double DecodeMilliseconds { get; private set; }
    internal double RenderMilliseconds { get; private set; }
    internal double BufferWaitMilliseconds { get; private set; }
    internal void AddDecode(double elapsed) => DecodeMilliseconds += elapsed;
    internal void AddRender(double elapsed) => RenderMilliseconds += elapsed;
    internal void AddBufferWait(double elapsed) => BufferWaitMilliseconds += elapsed;
    internal void AddSubmittedFrame() => Interlocked.Increment(ref frames);
}

internal sealed record VideoExportMemorySnapshot(string Stage, int Frames, double PrivateMiB, double WorkingMiB, double ManagedLiveMiB,
    double LastGcHeapMiB, double ManagedCommittedMiB, double TotalManagedAllocatedMiB, int Gen0Collections, int Gen1Collections, int Gen2Collections);
