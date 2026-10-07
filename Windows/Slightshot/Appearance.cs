using System.Windows.Media;
using Microsoft.Win32;

namespace Slightshot;

internal static class Appearance
{
    public static bool IsDark(bool taskbar = false)
    {
        try { using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"); return key?.GetValue(taskbar ? "SystemUsesLightTheme" : "AppsUseLightTheme") is int value && value == 0; }
        catch (System.Security.SecurityException) { return false; }
    }
    public static SolidColorBrush Brush(string hex) => AnnotationRenderer.Brush(hex);
}
