using System.IO;
using System.Diagnostics;
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
            byte[] pixels = new byte[checked(sourceWidth * sourceHeight * 4)];
            // Source warmup finishes before encoder creation, so instrumentation
            // attributes their native memory separately and reuses the first frame.
            long measured = Stopwatch.GetTimestamp();
            await sequential.GetFrameAsync(TimeSpan.Zero, pixels, cancellation);
            metrics?.AddDecode(Stopwatch.GetElapsedTime(measured).TotalMilliseconds);
            metrics?.RecordMemory("decoderWarmupComplete");
            int rate = quality.FramesPerSecond();
            long nextFrame = 0;
            metrics?.RecordMemory("beforeWriterPrepare");
            using (var writer = await VideoSinkWriter.OpenAsync(staging, sourceWidth, sourceHeight, quality, metrics))
            {
                metrics?.RecordMemory("writerPrepared");
                for (;;)
                {
                    cancellation.ThrowIfCancellationRequested();
                    var position = TimeSpan.FromTicks(nextFrame * TimeSpan.TicksPerSecond / rate);
                    if (position >= duration) break;
                    measured = Stopwatch.GetTimestamp();
                    await sequential.GetFrameAsync(position, pixels, cancellation);
                    metrics?.AddDecode(Stopwatch.GetElapsedTime(measured).TotalMilliseconds);
                    if (nextFrame == 0) metrics?.RecordMemory("firstFrameDecoded");
                    measured = Stopwatch.GetTimestamp();
                    await renderer.ComposeAsync(pixels, sourceWidth, sourceHeight, position, annotations, cancellation);
                    metrics?.AddRender(Stopwatch.GetElapsedTime(measured).TotalMilliseconds);
                    var sampleDuration = TimeSpan.FromTicks(Math.Min(TimeSpan.TicksPerSecond / rate, duration.Ticks - position.Ticks));
                    measured = Stopwatch.GetTimestamp();
                    await writer.WriteAsync(pixels, position, sampleDuration, cancellation, metrics);
                    metrics?.AddWriter(Stopwatch.GetElapsedTime(measured).TotalMilliseconds);
                    nextFrame++; metrics?.AddSubmittedFrame();
                    if (nextFrame is 1 or 15 or 30) metrics?.RecordMemory("submittedFrame" + nextFrame);
                    progress?.Report(Math.Min(100, (position + sampleDuration).TotalSeconds / duration.TotalSeconds * 100));
                }
                if (nextFrame == 0) throw new InvalidOperationException("No edited frames were exported.");
                await writer.FinishAsync(cancellation);
                metrics?.RecordMemory("writerFinalized");
            }
            // The native writer and its file handle are closed before publishing.
            metrics?.RecordMemory("writerReleased");
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
    private readonly List<VideoTransformDiagnostics> transforms = [];
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
    internal double ResizeMilliseconds { get; private set; }
    internal double WriterMilliseconds { get; private set; }
    internal double ColorConversionMilliseconds { get; private set; }
    internal uint MaximumWriterQueuedBytes { get; private set; }
    internal bool? EncoderWorkerThreadControlSupported { get; private set; }
    internal bool? EncoderWorkerThreadControlApplied { get; private set; }
    internal uint? ActualEncoderWorkerThreads { get; private set; }
    internal uint? ActualEncoderBFrames { get; private set; }
    internal ulong WriterSamplesReceived { get; private set; }
    internal ulong WriterSamplesEncoded { get; private set; }
    internal ulong WriterSamplesProcessed { get; private set; }
    internal void AddDecode(double elapsed) => DecodeMilliseconds += elapsed;
    internal void AddRender(double elapsed) => RenderMilliseconds += elapsed;
    internal void AddBufferWait(double elapsed) => BufferWaitMilliseconds += elapsed;
    internal void AddResize(double elapsed) => ResizeMilliseconds += elapsed;
    internal void AddWriter(double elapsed) => WriterMilliseconds += elapsed;
    internal void AddColorConversion(double elapsed) => ColorConversionMilliseconds += elapsed;
    internal void RecordWorkerSupport(bool supported) => EncoderWorkerThreadControlSupported = supported;
    internal void RecordWorkerThreads(uint actual, bool applied) { ActualEncoderWorkerThreads = actual; EncoderWorkerThreadControlApplied = applied; }
    internal void RecordBFrames(uint actual) => ActualEncoderBFrames = actual;
    internal VideoEncoderDiagnostics EncoderDiagnostics => new(EncoderWorkerThreadControlSupported, EncoderWorkerThreadControlApplied,
        ActualEncoderWorkerThreads, ActualEncoderBFrames, WriterSamplesReceived, WriterSamplesEncoded, WriterSamplesProcessed, transforms.ToArray());
    internal void RecordTransform(VideoTransformDiagnostics transform) => transforms.Add(transform);
    internal void AddWriterStatistics(uint bytes, ulong received, ulong encoded, ulong processed)
    {
        MaximumWriterQueuedBytes = Math.Max(MaximumWriterQueuedBytes, bytes);
        WriterSamplesReceived = Math.Max(WriterSamplesReceived, received); WriterSamplesEncoded = Math.Max(WriterSamplesEncoded, encoded); WriterSamplesProcessed = Math.Max(WriterSamplesProcessed, processed);
    }
    internal void AddSubmittedFrame() => Interlocked.Increment(ref frames);
}

internal sealed record VideoExportMemorySnapshot(string Stage, int Frames, double PrivateMiB, double WorkingMiB, double ManagedLiveMiB,
    double LastGcHeapMiB, double ManagedCommittedMiB, double TotalManagedAllocatedMiB, int Gen0Collections, int Gen1Collections, int Gen2Collections);
internal sealed record VideoEncoderDiagnostics(bool? WorkerThreadControlSupported, bool? WorkerThreadControlApplied,
    uint? ActualWorkerThreads, uint? ActualBFrames, ulong SamplesReceived, ulong SamplesEncoded, ulong SamplesProcessed,
    IReadOnlyList<VideoTransformDiagnostics> Transforms);
internal sealed record VideoTransformDiagnostics(uint Index, Guid Category, Guid ClassId, bool DisableFrameRateConversionApplied,
    uint? ActualFrameRateConversionDisabled);
