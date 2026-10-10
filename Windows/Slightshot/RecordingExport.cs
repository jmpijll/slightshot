using System.IO;
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage;
using Slightshot.Core;

namespace Slightshot;

internal static class RecordingExport
{
    internal static void ValidateDestination(string source, string destination)
    {
        if (StringComparer.OrdinalIgnoreCase.Equals(Path.GetFullPath(source), Path.GetFullPath(destination)))
            throw new InvalidOperationException("Choose a save location different from the temporary recording. The original video has been preserved.");
    }
    // Capture is converted explicitly to top-down, limited-range BT.709 NV12
    // before submission. Y rows and interleaved UV rows both use this stride.
    internal static VideoEncodingProperties FrameProperties(int width, int height, int framesPerSecond)
    {
        var properties = VideoEncodingProperties.CreateUncompressed(MediaEncodingSubtypes.Nv12, (uint)width, (uint)height);
        properties.FrameRate.Numerator = (uint)framesPerSecond; properties.FrameRate.Denominator = 1;
        properties.PixelAspectRatio.Numerator = properties.PixelAspectRatio.Denominator = 1;
        properties.Properties[new Guid("644b4e48-1e02-4516-b0eb-c01ca9d49ac6")] = checked((uint)width); // MF_MT_DEFAULT_STRIDE
        SetSdrColor(properties);
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
        SetSdrColor(profile.Video);
        return profile;
    }

    private static void SetSdrColor(VideoEncodingProperties properties)
    {
        // Supply the actual NV12 sample format before media-type negotiation.
        // Supplying BGRA and output tags alone still allowed the native SD
        // converter to produce 601 pixels under a 709 label.
        properties.Properties[new Guid("dbfbe4d7-0740-4ee0-8192-850ab0e21935")] = (uint)2; // MF_MT_VIDEO_PRIMARIES: BT.709
        properties.Properties[new Guid("5fb0fce9-be5c-4935-a811-ec838f8eed93")] = (uint)5; // MF_MT_TRANSFER_FUNCTION: BT.709
        properties.Properties[new Guid("c21b8ee5-b956-4071-8daf-325edf5cab11")] = (uint)2; // MF_MT_VIDEO_NOMINAL_RANGE: limited
        properties.Properties[new Guid("3e23d450-2c75-4d25-a00e-b91670d12327")] = (uint)1; // MF_MT_YUV_MATRIX: BT.709
    }

    internal static async Task SaveAsync(string source, string destination, RecordingQuality quality, int width, int height, CancellationToken cancellation, IProgress<double>? progress = null)
    {
        ValidateDestination(source, destination);
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
