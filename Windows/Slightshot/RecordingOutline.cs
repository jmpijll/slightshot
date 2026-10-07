using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using Slightshot.Core;

namespace Slightshot;

// An opaque HWND with a hollow native region: the screen remains interactive
// without the layered-window/display-affinity conflict on Windows 10.
internal sealed class RecordingOutline : Window
{
    private readonly RectD pixels;
    internal RecordingOutline(CapturedDisplay display, RectD selection)
    {
        pixels = selection.ToPixels(display.Scale, display.Scale, display.PixelWidth, display.PixelHeight);
        Title = "Recording area"; WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false; Topmost = true; ShowActivated = false; Focusable = false; IsHitTestVisible = false;
        Background = Appearance.Brush("#FF3B30");
        Width = pixels.Width / display.Scale; Height = pixels.Height / display.Scale;
        Left = (display.Left + pixels.X) / display.Scale; Top = (display.Top + pixels.Y) / display.Scale;
        var inner = new Border { BorderBrush = Appearance.Brush("#17171A"), BorderThickness = new Thickness(1), Margin = new Thickness(2) };
        Content = new Border { BorderBrush = Appearance.Brush("#17171A"), BorderThickness = new Thickness(1), Child = inner };
        SourceInitialized += (_, _) =>
        {
            IntPtr handle = new WindowInteropHelper(this).Handle;
            // WS_EX_TRANSPARENT / WS_EX_NOACTIVATE keep this passive boundary
            // out of keyboard focus and mouse hit testing.
            RecordingNative.SetWindowLong(handle, -20, RecordingNative.GetWindowLong(handle, -20) | 0x08000020);
            HwndSource.FromHwnd(handle)?.AddHook(HitTest);
            RecordingWindowExclusion.Exclude(this);
            NativeMethods.SetWindowPos(handle, new IntPtr(-1), display.Left + (int)pixels.X, display.Top + (int)pixels.Y, (int)pixels.Width, (int)pixels.Height, 0x0050);
            SetHollowRegion();
        };
        SizeChanged += (_, _) => SetHollowRegion();
        DpiChanged += (_, _) => SetHollowRegion();
    }

    private static IntPtr HitTest(IntPtr window, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message != 0x0084) return IntPtr.Zero; // WM_NCHITTEST
        handled = true; return new IntPtr(-1); // HTTRANSPARENT
    }

    private void SetHollowRegion()
    {
        IntPtr handle = new WindowInteropHelper(this).Handle;
        if (handle == IntPtr.Zero || !RecordingNative.GetWindowRect(handle, out var bounds)) return;
        int width = bounds.Right - bounds.Left, height = bounds.Bottom - bounds.Top;
        int border = Math.Max(1, (int)Math.Round(4 * NativeMethods.GetDpiForWindow(handle) / 96.0));
        IntPtr outer = RecordingNative.CreateRectRgn(0, 0, width, height);
        IntPtr inner = RecordingNative.CreateRectRgn(border, border, width - border, height - border);
        try
        {
            if (outer == IntPtr.Zero || inner == IntPtr.Zero || RecordingNative.CombineRgn(outer, outer, inner, 4) == 0)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Slightshot could not show the recording boundary.");
            if (RecordingNative.SetWindowRgn(handle, outer, true) == 0)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Slightshot could not show the recording boundary.");
            outer = IntPtr.Zero; // The window owns the region after success.
        }
        finally
        {
            if (inner != IntPtr.Zero) NativeMethods.DeleteObject(inner);
            if (outer != IntPtr.Zero) NativeMethods.DeleteObject(outer);
        }
    }
}
