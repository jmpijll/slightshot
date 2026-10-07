using System.Windows.Media;
using System.Windows;
using System.Windows.Interop;
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
    internal static void ApplyWindowTheme(Window window, bool? forceDark = null)
    {
        bool dark = forceDark ?? IsDark();
        window.FontFamily = new FontFamily("Segoe UI"); window.FontSize = 13;
        window.Background = Brush(dark ? "#222226" : "#F3F3F5"); window.Foreground = Brush(dark ? "#F3F3F5" : "#242426");
        window.Resources["TextBrush"] = window.Foreground;
        window.Resources["SecondaryBrush"] = Brush(dark ? "#A5A5AB" : "#727278");
        window.Resources["SurfaceBrush"] = Brush(dark ? "#303034" : "#FFFFFF");
        window.Resources["TabRailBrush"] = Brush(dark ? "#17171A" : "#E5E5E9");
        window.Resources["TabSelectedBrush"] = Brush(dark ? "#55555A" : "#FFFFFF");
        window.Resources["ButtonBrush"] = Brush(dark ? "#505056" : "#FFFFFF");
        window.Resources["BorderBrush"] = Brush(dark ? "#606066" : "#D0D0D6");
        window.Resources["HoverBrush"] = Brush(dark ? "#606068" : "#F0F0F4");
        window.Resources["SwitchBrush"] = Brush(dark ? "#66666C" : "#C8C8CE");
        window.Resources["InputBrush"] = Brush(dark ? "#26262A" : "#FAFAFC");
        window.Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("/Slightshot;component/SettingsTheme.xaml", UriKind.Relative) });
        window.SourceInitialized += (_, _) => { int value = dark ? 1 : 0; NativeMethods.DwmSetWindowAttribute(new WindowInteropHelper(window).Handle, 20, ref value, sizeof(int)); };
    }
}
