namespace Slightshot.Core;

// Fixed-size bilinear mapping, shared by all frames of a downscaled export.
// Source annotations are composited before this final image-size conversion.
public sealed class BgraResizer
{
    private readonly int sourceWidth, sourceHeight, width, height;
    private readonly int[] first, second, fraction;
    public BgraResizer(int sourceWidth, int sourceHeight, int width, int height)
    {
        if (Math.Min(Math.Min(sourceWidth, sourceHeight), Math.Min(width, height)) <= 0) throw new ArgumentOutOfRangeException(nameof(width));
        this.sourceWidth = sourceWidth; this.sourceHeight = sourceHeight; this.width = width; this.height = height;
        first = new int[width]; second = new int[width]; fraction = new int[width];
        for (int x = 0; x < width; x++)
        {
            double position = Math.Clamp((x + .5) * sourceWidth / width - .5, 0, sourceWidth - 1);
            first[x] = (int)position; second[x] = Math.Min(first[x] + 1, sourceWidth - 1);
            fraction[x] = (int)Math.Round((position - first[x]) * 256);
        }
    }
    public void Resize(ReadOnlySpan<byte> source, Span<byte> output)
    {
        if (source.Length < checked(sourceWidth * sourceHeight * 4) || output.Length < checked(width * height * 4)) throw new ArgumentException("Pixel buffers do not match the resize dimensions.");
        for (int y = 0; y < height; y++)
        {
            double position = Math.Clamp((y + .5) * sourceHeight / height - .5, 0, sourceHeight - 1);
            int row = (int)position, next = Math.Min(row + 1, sourceHeight - 1), weight = (int)Math.Round((position - row) * 256);
            for (int x = 0; x < width; x++)
            {
                int a = (row * sourceWidth + first[x]) * 4, b = (row * sourceWidth + second[x]) * 4;
                int c = (next * sourceWidth + first[x]) * 4, d = (next * sourceWidth + second[x]) * 4, target = (y * width + x) * 4;
                for (int channel = 0; channel < 4; channel++)
                {
                    int top = source[a + channel] * (256 - fraction[x]) + source[b + channel] * fraction[x];
                    int bottom = source[c + channel] * (256 - fraction[x]) + source[d + channel] * fraction[x];
                    output[target + channel] = (byte)((top * (256 - weight) + bottom * weight + 32768) >> 16);
                }
            }
        }
    }
}
