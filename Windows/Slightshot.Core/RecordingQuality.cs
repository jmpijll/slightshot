using System.Globalization;

namespace Slightshot.Core;

public enum RecordingQuality { Compact, Balanced, High }

public static class RecordingQualityOptions
{
    public static string Title(this RecordingQuality quality) => quality switch { RecordingQuality.Compact => "Small & fast", RecordingQuality.High => "High quality", _ => "Balanced" };
    public static int FramesPerSecond(this RecordingQuality quality) => quality switch { RecordingQuality.Compact => 15, RecordingQuality.High => 30, _ => 24 };
    public static int MaximumDimension(this RecordingQuality quality) => quality switch { RecordingQuality.Compact => 1280, RecordingQuality.High => 4096, _ => 1920 };
    public static (int Width, int Height) Dimensions(this RecordingQuality quality, int width, int height)
    {
        if (width <= 0 || height <= 0) throw new ArgumentOutOfRangeException(nameof(width), "A recording needs a nonempty region.");
        double scale = Math.Min(1, (double)quality.MaximumDimension() / Math.Max(width, height));
        return (Math.Max(2, (int)Math.Floor(width * scale / 2) * 2), Math.Max(2, (int)Math.Floor(height * scale / 2) * 2));
    }
    public static uint Bitrate(this RecordingQuality quality, int width, int height)
    {
        double bitsPerPixel = quality switch { RecordingQuality.Compact => 0.08, RecordingQuality.High => 0.24, _ => 0.14 };
        return (uint)Math.Max(150_000, width * (double)height * quality.FramesPerSecond() * bitsPerPixel);
    }
    public static string Detail(this RecordingQuality quality, int width, int height)
    {
        var size = quality.Dimensions(width, height);
        return string.Create(CultureInfo.InvariantCulture, $"{size.Width} × {size.Height} · {quality.FramesPerSecond()} fps · {quality.Bitrate(size.Width, size.Height) / 1_000_000.0:0.0} Mbps");
    }
}
