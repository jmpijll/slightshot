using System.IO;
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage;
using Slightshot.Core;

namespace Slightshot;

internal static class RecordingExport
{
    // GDI capture and WPF CopyPixels both produce top-down BGRA. The default
    // RGB media stride can be bottom-up; declare the positive stride explicitly
    // so the native color converter preserves the image's vertical orientation.
    internal static VideoEncodingProperties FrameProperties(int width, int height, int framesPerSecond)
    {
        var properties = VideoEncodingProperties.CreateUncompressed(MediaEncodingSubtypes.Bgra8, (uint)width, (uint)height);
        properties.FrameRate.Numerator = (uint)framesPerSecond; properties.FrameRate.Denominator = 1;
        properties.PixelAspectRatio.Numerator = properties.PixelAspectRatio.Denominator = 1;
        properties.Properties[new Guid("644b4e48-1e02-4516-b0eb-c01ca9d49ac6")] = checked((uint)(width * 4)); // MF_MT_DEFAULT_STRIDE
        return properties;
    }

    internal static MediaEncodingProfile Profile(RecordingQuality quality, int sourceWidth, int sourceHeight)
    {
        var size = quality.Dimensions(sourceWidth, sourceHeight);
        var profile = MediaEncodingProfile.CreateMp4(VideoEncodingQuality.HD1080p);
        profile.Audio = null;
        profile.Video.Width = (uint)size.Width; profile.Video.Height = (uint)size.Height;
        profile.Video.FrameRate.Numerator = (uint)quality.FramesPerSecond(); profile.Video.FrameRate.Denominator = 1;
        profile.Video.PixelAspectRatio.Numerator = profile.Video.PixelAspectRatio.Denominator = 1;
        profile.Video.Bitrate = quality.Bitrate(size.Width, size.Height);
        return profile;
    }

    internal static async Task SaveAsync(string source, string destination, RecordingQuality quality, int width, int height, CancellationToken cancellation, IProgress<double>? progress = null)
    {
        string staging = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(destination))!, ".slightshot-" + Guid.NewGuid().ToString("N") + ".mp4");
        try
        {
            cancellation.ThrowIfCancellationRequested();
            var input = await StorageFile.GetFileFromPathAsync(source).AsTask(cancellation);
            var folder = await StorageFolder.GetFolderFromPathAsync(Path.GetDirectoryName(staging)!).AsTask(cancellation);
            var output = await folder.CreateFileAsync(Path.GetFileName(staging), CreationCollisionOption.FailIfExists).AsTask(cancellation);
            // Explicitly own both streams so cancellation releases every file
            // handle before the staging file is removed or atomically renamed.
            using (var inputStream = await input.OpenReadAsync().AsTask(cancellation))
            using (var outputStream = await output.OpenAsync(FileAccessMode.ReadWrite).AsTask(cancellation))
            {
                var transcoder = new MediaTranscoder { HardwareAccelerationEnabled = true, AlwaysReencode = true };
                var prepared = await transcoder.PrepareStreamTranscodeAsync(inputStream, outputStream, Profile(quality, width, height)).AsTask(cancellation);
                if (!prepared.CanTranscode) throw new InvalidOperationException($"Windows could not export this recording ({prepared.FailureReason}).");
                await prepared.TranscodeAsync().AsTask(cancellation, progress);
            }
            cancellation.ThrowIfCancellationRequested();
            // Same-volume replacement only after a complete MP4 is finalized.
            if (File.Exists(destination)) File.Replace(staging, destination, null);
            else File.Move(staging, destination);
        }
        finally { try { File.Delete(staging); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
    }
}
