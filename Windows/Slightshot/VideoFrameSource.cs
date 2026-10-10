using System.Windows.Media;
using System.Windows.Media.Imaging;
using Windows.Storage;
using Slightshot.Core;

namespace Slightshot;

// Preview and export interpret the same native NV12 planes and color metadata.
// Decode/seek/resize stays off the UI thread; only a bounded frozen bitmap is
// displayed. Source pixels retain their original annotation coordinate system.
internal sealed class VideoFrameSource : IDisposable
{
    private VideoSequentialDecoder? frames;
    private ExactSizeBufferPool.BufferLease? pixelLease;
    private BgraResizer? resizer;
    private byte[]? displayed;
    private int displayWidth, displayHeight;
    private readonly string path;
    private readonly SemaphoreSlim decoder = new(1, 1);
    private bool disposed;
    internal int Width { get; }
    internal int Height { get; }
    internal TimeSpan Duration { get; }
    private VideoFrameSource(string path, int width, int height, TimeSpan duration)
    {
        this.path = path; Width = width; Height = height; Duration = duration;
    }
    internal static async Task<VideoFrameSource> OpenAsync(string path, CancellationToken cancellation = default)
    {
        var file = await StorageFile.GetFileFromPathAsync(path).AsTask(cancellation);
        var properties = await file.Properties.GetVideoPropertiesAsync().AsTask(cancellation);
        // Use the same normalized track duration as annotated export, rather
        // than adding the original positive first presentation timestamp.
        if (properties.Width == 0 || properties.Height == 0 || properties.Duration <= TimeSpan.Zero)
            throw new InvalidOperationException("This recording has no playable video frames.");
        return new(file.Path, checked((int)properties.Width), checked((int)properties.Height), properties.Duration);
    }
    internal async Task<BitmapSource> GetFrameAsync(TimeSpan position, CancellationToken cancellation = default, int maximumWidth = 0)
    {
        await decoder.WaitAsync(cancellation).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            return await Task.Run(async () =>
            {
                cancellation.ThrowIfCancellationRequested();
                frames ??= await VideoSequentialDecoder.OpenAsync(path, Width, Height, canSeek: true).ConfigureAwait(false);
                pixelLease ??= VideoPixelBuffers.Shared.Rent(checked(Width * Height * 4));
                var safe = TimeSpan.FromTicks(Math.Clamp(position.Ticks, 0, Math.Max(0, Duration.Ticks - 1)));
                await frames.GetFrameAsync(safe, pixelLease.Pixels, cancellation).ConfigureAwait(false);
                cancellation.ThrowIfCancellationRequested();
                int width = maximumWidth > 0 ? Math.Min(Width, maximumWidth) : Width;
                int height = Math.Max(1, (int)Math.Round((double)width * Height / Width));
                byte[] bytes = pixelLease.Pixels;
                if (width != Width || height != Height)
                {
                    if (width != displayWidth || height != displayHeight)
                    {
                        resizer = new(Width, Height, width, height);
                        displayed = new byte[checked(width * height * 4)];
                        displayWidth = width; displayHeight = height;
                    }
                    resizer!.Resize(bytes, displayed!); bytes = displayed!;
                }
                cancellation.ThrowIfCancellationRequested();
                var bitmap = BitmapSource.Create(width, height, 96, 96, PixelFormats.Pbgra32, null, bytes, checked(width * 4));
                bitmap.Freeze(); return bitmap;
            }, cancellation).ConfigureAwait(false);
        }
        finally { decoder.Release(); }
    }
    internal async Task SuspendPreviewAsync(CancellationToken cancellation = default)
    {
        await decoder.WaitAsync(cancellation).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            // The frozen display bitmap remains usable. Drain and release the
            // native reader on background work before returning its leases;
            // seek/play lazily opens a fresh reader for the same source.
            await Task.Run(ReleasePreview).ConfigureAwait(false);
        }
        finally { decoder.Release(); }
    }
    private void ReleasePreview()
    {
        var previous = frames; frames = null;
        try { previous?.Dispose(); }
        finally
        {
            pixelLease?.Dispose(); pixelLease = null;
            resizer = null; displayed = null; displayWidth = displayHeight = 0;
        }
    }
    public void Dispose()
    {
        // Call only after active requests finish, on background work when a
        // reader is open. Its owned MTA releases native state before Join ends.
        if (disposed) return;
        disposed = true; ReleasePreview(); decoder.Dispose();
    }
}
