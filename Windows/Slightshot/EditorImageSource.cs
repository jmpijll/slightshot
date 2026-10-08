using System.IO;
using System.Windows;
using System.Windows.Media.Imaging;
using Slightshot.Core;

namespace Slightshot;

/// Frozen pixels and their point mapping; no monitor or screen placement implied.
public sealed record EditorImageSource(BitmapSource Image, double Scale)
{
    public int PixelWidth => Image.PixelWidth;
    public int PixelHeight => Image.PixelHeight;
    public double Width => PixelWidth / Scale;
    public double Height => PixelHeight / Scale;
    public RectD Bounds => new(0, 0, Width, Height);

    public static EditorImageSource Clipboard(BitmapSource image, double width, double height)
        => new(image, ImageEditorGeometry.FitScale(image.PixelWidth, image.PixelHeight, width, height));
}

internal static class ClipboardImage
{
    public static BitmapSource? Read()
    {
        var data = System.Windows.Clipboard.GetDataObject();
        if (data == null) return null;
        // PNG carries original pixels and alpha even when the Bitmap clipboard
        // representation is an opaque, DPI-adjusted fallback. Never read file drops.
        foreach (string format in new[] { "PNG", DataFormats.Tiff })
        {
            if (!data.GetDataPresent(format, false)) continue;
            using var bytes = data.GetData(format, false) switch
            {
                MemoryStream stream => new MemoryStream(stream.ToArray()),
                byte[] array => new MemoryStream(array),
                _ => null
            };
            if (bytes != null)
            {
                try
                {
                    var image = BitmapDecoder.Create(bytes, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad).Frames[0];
                    image.Freeze(); return image;
                }
                catch (Exception error) when (error is FileFormatException or NotSupportedException or ArgumentException) { }
            }
        }
        if (!data.GetDataPresent(DataFormats.Bitmap, false)) return null;
        var fallback = System.Windows.Clipboard.GetImage();
        fallback?.Freeze(); return fallback;
    }
}
