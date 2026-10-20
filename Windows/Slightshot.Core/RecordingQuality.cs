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
        string tradeoff = quality switch
        {
            RecordingQuality.Compact => "Prioritize smaller files and quicker saving",
            RecordingQuality.High => "Preserve more detail and smoother motion",
            _ => "Balance detail and file size"
        };
        return string.Create(CultureInfo.InvariantCulture, $"{size.Width} × {size.Height} · {quality.FramesPerSecond()} fps\n{tradeoff}");
    }
}

// Source pixels read from the desktop and the even-sized frame they become.
public readonly record struct RecordingGeometry(int SourceWidth, int SourceHeight, int Width, int Height)
{
    public bool IsPixelExact => SourceWidth == Width && SourceHeight == Height;

    public static RecordingGeometry Create(int sourceWidth, int sourceHeight, int requestedWidth, int requestedHeight)
    {
        if (sourceWidth <= 0 || sourceHeight <= 0) throw new ArgumentOutOfRangeException(nameof(sourceWidth), "A recording needs a nonempty region.");
        var size = RecordingQuality.High.Dimensions(requestedWidth, requestedHeight);
        return new(Crop(sourceWidth, size.Width), Crop(sourceHeight, size.Height), size.Width, size.Height);
    }

    // Rounding an odd axis down to even drops its last pixel row or column;
    // resampling the rest by a fraction of a pixel would soften every frame.
    private static int Crop(int source, int encoded) => encoded == (source & ~1) ? encoded : source;
}
