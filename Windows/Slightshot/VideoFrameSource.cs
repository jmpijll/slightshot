using System.Windows.Media;
using System.Windows.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Media.Editing;
using Windows.Storage;

namespace Slightshot;

// One decoder per preview/export, with serialized native requests. Requesting
// source dimensions preserves the annotation coordinate system at every size.
internal sealed class VideoFrameSource : IDisposable
{
    private readonly MediaComposition composition;
    private readonly SemaphoreSlim decoder = new(1, 1);
    private bool disposed;
    internal int Width { get; }
    internal int Height { get; }
    internal TimeSpan Duration { get; }
    private VideoFrameSource(MediaComposition composition, int width, int height, TimeSpan duration)
    {
        this.composition = composition; Width = width; Height = height; Duration = duration;
    }
    internal static async Task<VideoFrameSource> OpenAsync(string path, CancellationToken cancellation = default)
    {
        var file = await StorageFile.GetFileFromPathAsync(path).AsTask(cancellation);
        var properties = await file.Properties.GetVideoPropertiesAsync().AsTask(cancellation);
        var clip = await MediaClip.CreateFromFileAsync(file).AsTask(cancellation);
        if (properties.Width == 0 || properties.Height == 0 || clip.OriginalDuration <= TimeSpan.Zero)
            throw new InvalidOperationException("This recording has no playable video frames.");
        var composition = new MediaComposition(); composition.Clips.Add(clip);
        return new(composition, checked((int)properties.Width), checked((int)properties.Height), clip.OriginalDuration);
    }
    internal async Task<BitmapSource> GetFrameAsync(TimeSpan position, CancellationToken cancellation = default, int maximumWidth = 0)
    {
        await decoder.WaitAsync(cancellation).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            // The exact endpoint lies outside the composition. Show its last
            // frame when a user drags the playhead to the end of the clip.
            var safe = TimeSpan.FromTicks(Math.Clamp(position.Ticks, 0, Math.Max(0, Duration.Ticks - 1)));
            int width = maximumWidth > 0 ? Math.Min(Width, maximumWidth) : Width;
            int height = Math.Max(1, (int)Math.Round((double)width * Height / Width));
            using var thumbnail = await composition.GetThumbnailAsync(safe, width, height, VideoFramePrecision.NearestFrame).AsTask(cancellation).ConfigureAwait(false);
            var image = await Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(thumbnail).AsTask(cancellation).ConfigureAwait(false);
            var data = await image.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
                new BitmapTransform(), ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage).AsTask(cancellation).ConfigureAwait(false);
            byte[] bytes = data.DetachPixelData();
            var bitmap = BitmapSource.Create(checked((int)image.PixelWidth), checked((int)image.PixelHeight), 96, 96,
                PixelFormats.Pbgra32, null, bytes, checked((int)image.PixelWidth * 4));
            bitmap.Freeze(); return bitmap;
        }
        finally { decoder.Release(); }
    }
    public void Dispose()
    {
        // Call only after active decode requests finish. Native composition
        // releases the clip/file before RecordingSession removes its source.
        if (disposed) return;
        disposed = true; composition.Clips.Clear();
        decoder.Dispose();
    }
}
