namespace Slightshot.Core;

public static class ImageEditorGeometry
{
    // Fit changes only the view mapping. Output dimensions always use source pixels.
    public static double FitScale(int pixelWidth, int pixelHeight, double availableWidth, double availableHeight)
    {
        if (pixelWidth < 1 || pixelHeight < 1 || availableWidth <= 0 || availableHeight <= 0)
            throw new ArgumentOutOfRangeException(nameof(pixelWidth));
        return Math.Max(1, Math.Max(pixelWidth / availableWidth, pixelHeight / availableHeight));
    }
}
