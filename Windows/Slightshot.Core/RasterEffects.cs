namespace Slightshot.Core;

// Operates on premultiplied BGRA pixels. Visual obscuring, not secure redaction.
public static class RasterEffects
{
    public const double BlurRadius = 8;
    public const double PixelBlockSize = 12;

    public static RectD? Region(Annotation annotation, RectD selection)
    {
        if (!annotation.IsRasterEffect || annotation.Points.Length < 2) return null;
        var rect = RectD.Between(annotation.Points[0], annotation.Points[^1]);
        double left = Math.Max(rect.Left, selection.Left), top = Math.Max(rect.Top, selection.Top);
        double right = Math.Min(rect.Right, selection.Right), bottom = Math.Min(rect.Bottom, selection.Bottom);
        return right > left && bottom > top ? new(left, top, right - left, bottom - top) : null;
    }

    public static void Pixelate(byte[] pixels, int width, int height, int blockSize)
    {
        blockSize = Math.Max(1, blockSize);
        Span<long> sum = stackalloc long[4];
        for (int top = 0; top < height; top += blockSize)
        for (int left = 0; left < width; left += blockSize)
        {
            int right = Math.Min(width, left + blockSize), bottom = Math.Min(height, top + blockSize);
            sum.Clear();
            for (int y = top; y < bottom; y++)
            for (int x = left; x < right; x++)
                for (int channel = 0; channel < 4; channel++) sum[channel] += pixels[(y * width + x) * 4 + channel];
            int count = (right - left) * (bottom - top);
            for (int channel = 0; channel < 4; channel++) sum[channel] = (sum[channel] + count / 2) / count;
            for (int y = top; y < bottom; y++)
            for (int x = left; x < right; x++)
                for (int channel = 0; channel < 4; channel++) pixels[(y * width + x) * 4 + channel] = (byte)sum[channel];
        }
    }

    // Three sliding box passes approximate a Gaussian in linear time, avoiding
    // a radius-dependent convolution for every pixel during a rectangle drag.
    public static void Blur(byte[] pixels, int width, int height, double radius)
    {
        var scratch = new byte[pixels.Length];
        foreach (int boxRadius in BoxRadii(radius))
        {
            if (boxRadius == 0) continue;
            BoxPass(pixels, scratch, width, height, boxRadius, true);
            BoxPass(scratch, pixels, width, height, boxRadius, false);
        }
    }

    public static int BlurPadding(double radius) => BoxRadii(radius).Sum();

    private static int[] BoxRadii(double radius)
    {
        double sigma = Math.Max(0, radius);
        int lower = (int)Math.Floor(Math.Sqrt(4 * sigma * sigma + 1));
        if (lower % 2 == 0) lower--;
        lower = Math.Max(1, lower);
        int lowerCount = Math.Clamp((int)Math.Round((12 * sigma * sigma - 3 * lower * lower - 12 * lower - 9) / (-4 * lower - 4)), 0, 3);
        return Enumerable.Range(0, 3).Select(i => (lower + (i < lowerCount ? 0 : 2) - 1) / 2).ToArray();
    }

    private static void BoxPass(byte[] source, byte[] target, int width, int height, int radius, bool horizontal)
    {
        int length = horizontal ? width : height, rows = horizontal ? height : width;
        int step = horizontal ? 4 : width * 4, rowStep = horizontal ? width * 4 : 4;
        int count = radius * 2 + 1;
        for (int row = 0; row < rows; row++)
        for (int channel = 0; channel < 4; channel++)
        {
            int start = row * rowStep + channel, sum = 0;
            for (int offset = -radius; offset <= radius; offset++) sum += source[start + Math.Clamp(offset, 0, length - 1) * step];
            for (int position = 0; position < length; position++)
            {
                target[start + position * step] = (byte)((sum + count / 2) / count);
                sum += source[start + Math.Clamp(position + radius + 1, 0, length - 1) * step]
                    - source[start + Math.Clamp(position - radius, 0, length - 1) * step];
            }
        }
    }
}
