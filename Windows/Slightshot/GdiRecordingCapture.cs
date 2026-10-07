using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace Slightshot;

// One top-down BGRA DIB reused for the whole recording. StretchBlt crops/scales
// the live desktop directly; no full-monitor bitmap or unbounded frame queue.
internal sealed class GdiRecordingCapture : IDisposable
{
    private readonly int left, top, sourceWidth, sourceHeight, width, height;
    private readonly bool includeCursor;
    private IntPtr memory, bitmap, previous, pixels;

    internal GdiRecordingCapture(int left, int top, int sourceWidth, int sourceHeight, int width, int height, bool includeCursor)
    {
        this.left = left; this.top = top; this.sourceWidth = sourceWidth; this.sourceHeight = sourceHeight; this.width = width; this.height = height; this.includeCursor = includeCursor;
        IntPtr screen = RecordingNative.GetDC(IntPtr.Zero);
        try
        {
            memory = RecordingNative.CreateCompatibleDC(screen);
            var info = new RecordingNative.BitmapInfo { Header = new() { Size = 40, Width = width, Height = -height, Planes = 1, BitCount = 32 } };
            bitmap = RecordingNative.CreateDIBSection(screen, ref info, 0, out pixels, IntPtr.Zero, 0);
            if (screen == IntPtr.Zero || memory == IntPtr.Zero || bitmap == IntPtr.Zero || pixels == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "The screen capture buffer could not be created.");
            previous = RecordingNative.SelectObject(memory, bitmap);
            RecordingNative.SetStretchBltMode(memory, 4);
        }
        catch { Dispose(); throw; }
        finally { if (screen != IntPtr.Zero) RecordingNative.ReleaseDC(IntPtr.Zero, screen); }
    }

    internal byte[] Capture()
    {
        bool connected = false;
        NativeMethods.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr monitor, IntPtr dc, ref NativeMethods.NativeRect bounds, IntPtr data) =>
        {
            if (left >= bounds.Left && top >= bounds.Top && left + sourceWidth <= bounds.Right && top + sourceHeight <= bounds.Bottom) connected = true;
            return true;
        }, IntPtr.Zero);
        if (!connected) throw new InvalidOperationException("The selected display is no longer available.");
        RecordingWindowExclusion.ExcludeOwnWindows();
        // A screen DC must be released by the thread that acquired it. Media
        // callbacks can change worker threads, so only the memory DIB persists.
        IntPtr screen = RecordingNative.GetDC(IntPtr.Zero);
        try
        {
            if (screen == IntPtr.Zero || !RecordingNative.StretchBlt(memory, 0, 0, width, height, screen, left, top, sourceWidth, sourceHeight, 0x40CC0020))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "The selected screen area could not be recorded.");
        }
        finally { if (screen != IntPtr.Zero) RecordingNative.ReleaseDC(IntPtr.Zero, screen); }
        if (includeCursor) DrawCursor();
        if (!RecordingNative.GdiFlush()) throw new Win32Exception(Marshal.GetLastWin32Error(), "The recording frame could not be completed.");
        var bytes = new byte[checked(width * height * 4)];
        Marshal.Copy(pixels, bytes, 0, bytes.Length);
        // GDI's reserved alpha is not defined. Video samples must be opaque.
        for (int index = 3; index < bytes.Length; index += 4) bytes[index] = 255;
        return bytes;
    }

    private void DrawCursor()
    {
        var cursor = new NativeMethods.CursorInfo { Size = Marshal.SizeOf<NativeMethods.CursorInfo>() };
        if (!NativeMethods.GetCursorInfo(ref cursor) || (cursor.Flags & 1) == 0 || !NativeMethods.GetIconInfo(cursor.Cursor, out var icon)) return;
        try
        {
            IntPtr cursorBitmap = icon.Color != IntPtr.Zero ? icon.Color : icon.Mask;
            RecordingNative.GetObject(cursorBitmap, Marshal.SizeOf<RecordingNative.Bitmap>(), out var dimensions);
            int cursorHeight = icon.Color != IntPtr.Zero ? dimensions.Height : dimensions.Height / 2;
            double scaleX = (double)width / sourceWidth, scaleY = (double)height / sourceHeight;
            NativeMethods.DrawIconEx(memory, (int)Math.Round((cursor.Position.X - left - icon.HotspotX) * scaleX), (int)Math.Round((cursor.Position.Y - top - icon.HotspotY) * scaleY), cursor.Cursor,
                Math.Max(1, (int)Math.Round(dimensions.Width * scaleX)), Math.Max(1, (int)Math.Round(cursorHeight * scaleY)), 0, IntPtr.Zero, 3);
        }
        finally { if (icon.Mask != IntPtr.Zero) NativeMethods.DeleteObject(icon.Mask); if (icon.Color != IntPtr.Zero) NativeMethods.DeleteObject(icon.Color); }
    }

    public void Dispose()
    {
        if (previous != IntPtr.Zero && memory != IntPtr.Zero) RecordingNative.SelectObject(memory, previous);
        if (bitmap != IntPtr.Zero) NativeMethods.DeleteObject(bitmap);
        if (memory != IntPtr.Zero) RecordingNative.DeleteDC(memory);
        memory = bitmap = previous = pixels = IntPtr.Zero;
    }
}

internal static class RecordingWindowExclusion
{
    internal static void Exclude(Window window)
    {
        IntPtr handle = new WindowInteropHelper(window).EnsureHandle();
        if (!RecordingNative.SetWindowDisplayAffinity(handle, 0x11)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Slightshot could not hide its recording controls from the video.");
    }
    internal static void ExcludeOwnWindows()
    {
        int error = 0;
        RecordingNative.EnumWindows((window, _) =>
        {
            RecordingNative.GetWindowThreadProcessId(window, out uint process);
            if (process == Environment.ProcessId && RecordingNative.IsWindowVisible(window) && !RecordingNative.SetWindowDisplayAffinity(window, 0x11)) error = Marshal.GetLastWin32Error();
            return true;
        }, IntPtr.Zero);
        if (error != 0) throw new Win32Exception(error, "Slightshot could not hide its windows from the recording.");
    }
}

internal static class RecordingNative
{
    [DllImport("user32.dll")] internal static extern IntPtr GetDC(IntPtr window);
    [DllImport("user32.dll")] internal static extern int ReleaseDC(IntPtr window, IntPtr dc);
    [DllImport("gdi32.dll", SetLastError = true)] internal static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll", SetLastError = true)] internal static extern IntPtr CreateDIBSection(IntPtr dc, ref BitmapInfo info, uint usage, out IntPtr bits, IntPtr section, uint offset);
    [DllImport("gdi32.dll")] internal static extern IntPtr SelectObject(IntPtr dc, IntPtr value);
    [DllImport("gdi32.dll")] internal static extern int SetStretchBltMode(IntPtr dc, int mode);
    [DllImport("gdi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GdiFlush();
    [DllImport("gdi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool StretchBlt(IntPtr destination, int x, int y, int width, int height, IntPtr source, int sourceX, int sourceY, int sourceWidth, int sourceHeight, uint operation);
    [DllImport("gdi32.dll", EntryPoint = "GetObjectW")] internal static extern int GetObject(IntPtr value, int size, out Bitmap bitmap);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetWindowDisplayAffinity(IntPtr window, uint affinity);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool EnumWindows(WindowCallback callback, IntPtr data);
    [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool IsWindowVisible(IntPtr window);
    internal delegate bool WindowCallback(IntPtr window, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] internal struct BitmapInfo { internal BitmapInfoHeader Header; internal uint Color; }
    [StructLayout(LayoutKind.Sequential)] internal struct BitmapInfoHeader { internal uint Size; internal int Width, Height; internal ushort Planes, BitCount; internal uint Compression, ImageSize; internal int XPixels, YPixels; internal uint Colors, ImportantColors; }
    [StructLayout(LayoutKind.Sequential)] internal struct Bitmap { internal int Type, Width, Height, WidthBytes; internal ushort Planes, BitsPixel; internal IntPtr Bits; }
}
