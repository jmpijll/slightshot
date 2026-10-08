using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Imaging;

namespace Slightshot;

public sealed record CapturedDisplay(BitmapSource Image, int Left, int Top, int PixelWidth, int PixelHeight, double Scale)
{
    public EditorImageSource Source => new(Image, Scale);
    public double Width => PixelWidth / Scale;
    public double Height => PixelHeight / Scale;
}

internal static class ScreenCapture
{
    // Freeze every monitor before creating any overlays so none appear in another capture.
    public static List<CapturedDisplay> CaptureAll(bool includeCursor)
    {
        var displays = new List<CapturedDisplay>();
        bool success = NativeMethods.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr monitor, IntPtr dc, ref NativeMethods.NativeRect r, IntPtr data) =>
        {
            int width = r.Right - r.Left, height = r.Bottom - r.Top;
            NativeMethods.GetDpiForMonitor(monitor, 0, out uint dpi, out _);
            using var bitmap = new Bitmap(width, height, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            using (var graphics = Graphics.FromImage(bitmap))
            {
                graphics.CopyFromScreen(r.Left, r.Top, 0, 0, new System.Drawing.Size(width, height), CopyPixelOperation.SourceCopy);
                if (includeCursor) DrawCursor(graphics, r);
            }
            IntPtr handle = bitmap.GetHbitmap();
            try
            {
                var source = Imaging.CreateBitmapSourceFromHBitmap(handle, IntPtr.Zero, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                source.Freeze();
                displays.Add(new(source, r.Left, r.Top, width, height, (dpi == 0 ? 96 : dpi) / 96.0));
            }
            finally { NativeMethods.DeleteObject(handle); }
            return true;
        }, IntPtr.Zero);
        if (!success || displays.Count == 0) throw new InvalidOperationException("Slightshot could not capture the displays.");
        return displays;
    }

    public static CapturedDisplay UnderPointer(IReadOnlyList<CapturedDisplay> displays)
    {
        NativeMethods.GetCursorPos(out var point);
        return displays.FirstOrDefault(d => point.X >= d.Left && point.X < d.Left + d.PixelWidth && point.Y >= d.Top && point.Y < d.Top + d.PixelHeight) ?? displays[0];
    }

    private static void DrawCursor(Graphics graphics, NativeMethods.NativeRect monitor)
    {
        var cursor = new NativeMethods.CursorInfo { Size = Marshal.SizeOf<NativeMethods.CursorInfo>() };
        if (!NativeMethods.GetCursorInfo(ref cursor) || (cursor.Flags & 1) == 0 || !NativeMethods.GetIconInfo(cursor.Cursor, out var icon)) return;
        try
        {
            var dc = graphics.GetHdc();
            try { NativeMethods.DrawIconEx(dc, cursor.Position.X - monitor.Left - (int)icon.HotspotX, cursor.Position.Y - monitor.Top - (int)icon.HotspotY, cursor.Cursor, 0, 0, 0, IntPtr.Zero, 3); }
            finally { graphics.ReleaseHdc(dc); }
        }
        finally
        {
            if (icon.Mask != IntPtr.Zero) NativeMethods.DeleteObject(icon.Mask);
            if (icon.Color != IntPtr.Zero) NativeMethods.DeleteObject(icon.Color);
        }
    }
}
