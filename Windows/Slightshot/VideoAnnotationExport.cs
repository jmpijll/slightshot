using System.IO;
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
        IReadOnlyList<TimedAnnotation> annotations, CancellationToken cancellation, IProgress<double>? progress = null)
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
            using var decoder = await VideoFrameSource.OpenAsync(source, cancellation);
            using var renderer = new VideoRenderWorker();
            using var frames = new RecordingFrameBuffers(checked(decoder.Width * decoder.Height * 4));
            using var samples = new SemaphoreSlim(1, 1);
            using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
            int active = 0; bool accepting = true;
            object lifetime = new();
            TaskCompletionSource drained = new(TaskCreationOptions.RunContinuationsAsynchronously);
            Exception? sampleError = null;
            long nextFrame = 0;
            var properties = VideoEncodingProperties.CreateUncompressed(MediaEncodingSubtypes.Bgra8, (uint)decoder.Width, (uint)decoder.Height);
            int rate = quality.FramesPerSecond();
            properties.FrameRate.Numerator = (uint)rate; properties.FrameRate.Denominator = 1;
            properties.PixelAspectRatio.Numerator = properties.PixelAspectRatio.Denominator = 1;
            var media = new MediaStreamSource(new VideoStreamDescriptor(properties)) { Duration = decoder.Duration, CanSeek = false, BufferTime = TimeSpan.Zero };
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
                    if (position >= decoder.Duration) return;
                    var image = await decoder.GetFrameAsync(position, stop.Token);
                    var composed = await renderer.RenderAsync(image, position, annotations, stop.Token);
                    frame = await frames.RentAsync(stop.Token);
                    composed.CopyPixels(frame.Pixels, decoder.Width * 4, 0);
                    stop.Token.ThrowIfCancellationRequested();
                    sample = MediaStreamSample.CreateFromBuffer(frame.Pixels.AsBuffer(), position);
                    sample.Duration = TimeSpan.FromTicks(Math.Min(TimeSpan.TicksPerSecond / rate, decoder.Duration.Ticks - position.Ticks));
                    sample.KeyFrame = true;
                    var submitted = frame;
                    processed = (completed, _) => { completed.Processed -= processed; submitted.Dispose(); };
                    sample.Processed += processed;
                    args.Request.Sample = sample; frame = null; nextFrame++;
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
                var prepared = await transcoder.PrepareMediaStreamSourceTranscodeAsync(media, output, RecordingExport.Profile(quality, width, height)).AsTask(cancellation);
                if (!prepared.CanTranscode) throw new InvalidOperationException($"Windows could not export the edited recording ({prepared.FailureReason}).");
                await prepared.TranscodeAsync().AsTask(cancellation, progress);
                if (sampleError != null) throw new InvalidOperationException("A video frame could not be rendered.", sampleError);
                if (nextFrame == 0) throw new InvalidOperationException("No edited frames were exported.");
            }
            finally
            {
                lock (lifetime) { accepting = false; if (active == 0) drained.TrySetResult(); }
                stop.Cancel(); media.Starting -= Starting; media.SampleRequested -= SampleRequested;
                await drained.Task;
            }
            cancellation.ThrowIfCancellationRequested();
            if (File.Exists(destination)) File.Replace(staging, destination, null);
            else File.Move(staging, destination);
        }
        finally { try { File.Delete(staging); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
    }
}
