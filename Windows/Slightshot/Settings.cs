using System.IO;
using System.Text.Json;
using Slightshot.Core;

namespace Slightshot;

public sealed class Settings
{
    private static readonly string SettingsPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Slightshot", "settings.json");
    public ImageFormat ImageFormat { get; set; } = ImageFormat.Png;
    public double JpegQuality { get; set; } = 0.9;
    public string SaveDirectory { get; set; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "Screenshots");
    public string FilenameTemplate { get; set; } = "Screenshot {date} at {time}";
    public bool CopyAfterSave { get; set; }
    public bool ShowMagnifier { get; set; } = true;
    public bool ShowDimensions { get; set; } = true;
    public double DimOpacity { get; set; } = 0.45;
    public string AnnotationColor { get; set; } = "#FF3B30";
    public double LineWidth { get; set; } = 3;
    public double FontSize { get; set; } = 18;
    public bool RememberLastTool { get; set; } = true;
    public bool PlaySound { get; set; } = true;
    public bool ShowNotification { get; set; }
    public DefaultAction DefaultAction { get; set; } = DefaultAction.Copy;
    public bool CaptureCursor { get; set; }
    public bool NativeResolution { get; set; } = true;
    public HotKey CaptureAreaHotKey { get; set; } = new(0x39, 0x06);
    public HotKey SaveFullScreenHotKey { get; set; } = new(0x38, 0x06);
    public HotKey CopyFullScreenHotKey { get; set; } = new(0x37, 0x06);

    public static Settings Load()
    {
        try
        {
            var settings = File.Exists(SettingsPath) ? JsonSerializer.Deserialize<Settings>(File.ReadAllText(SettingsPath)) ?? new() : new Settings();
            settings.JpegQuality = Clamp(settings.JpegQuality, 0.3, 1, 0.9);
            settings.DimOpacity = Clamp(settings.DimOpacity, 0, 0.85, 0.45);
            settings.LineWidth = Clamp(settings.LineWidth, 1, 12, 3);
            settings.FontSize = Clamp(settings.FontSize, 10, 48, 18);
            if (string.IsNullOrWhiteSpace(settings.SaveDirectory)) settings.SaveDirectory = new Settings().SaveDirectory;
            if (!OverlayStyle.Swatches.Contains(settings.AnnotationColor)) settings.AnnotationColor = "#FF3B30";
            return settings;
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException) { return new(); }
    }

    private static double Clamp(double value, double min, double max, double fallback) => double.IsFinite(value) ? Math.Clamp(value, min, max) : fallback;
    public void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(SettingsPath)!);
        string temporary = SettingsPath + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temporary, SettingsPath, true);
    }
}
