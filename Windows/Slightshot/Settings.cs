using System.IO;
using System.Text.Json;
using Slightshot.Core;

namespace Slightshot;

public sealed class Settings
{
    private static readonly string SettingsPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Slightshot", "settings.json");
    private string path = SettingsPath;
    private bool preserveFile;
    public ImageFormat ImageFormat { get; set; } = ImageFormat.Png;
    public double JpegQuality { get; set; } = 0.9;
    public RecordingQuality RecordingQuality { get; set; } = RecordingQuality.Balanced;
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

    public static Settings Load(out string? notice) => Load(SettingsPath, out notice);
    internal static Settings Load(string path, out string? notice)
    {
        var (settings, recovery) = SettingsFile.Read<Settings>(path, DateTime.Now, Repair);
        settings.path = path;
        settings.preserveFile = recovery is { BackupPath: null };
        notice = recovery switch
        {
            null => null,
            { BackupPath: null } => $"Slightshot could not use {Path.GetFileName(path)} or keep a copy of it, so the file was left unchanged. Changes made now will not be saved.",
            { ResetFields.Count: 0 } => $"Slightshot could not read its settings and is using the defaults. The old file was kept as {Path.GetFileName(recovery.BackupPath)}.",
            _ => $"Some settings were invalid and were reset: {string.Join(", ", recovery.ResetFields.Take(3))}{(recovery.ResetFields.Count > 3 ? $" and {recovery.ResetFields.Count - 3} more" : "")}. The old file was kept as {Path.GetFileName(recovery.BackupPath)}."
        };
        return settings;
    }

    private static object? Repair(string field, object value) => (field, value) switch
    {
        (nameof(JpegQuality), double quality) => Clamp(quality, 0.3, 1),
        (nameof(DimOpacity), double opacity) => Clamp(opacity, 0, 0.85),
        (nameof(LineWidth), double width) => Clamp(width, 1, 12),
        (nameof(FontSize), double size) => Clamp(size, 10, 48),
        (nameof(SaveDirectory), string directory) => string.IsNullOrWhiteSpace(directory) ? null : directory,
        (nameof(AnnotationColor), string color) => OverlayStyle.Swatches.Contains(color) ? color : null,
        (_, HotKey { IsValid: false }) => null,
        _ => value
    };
    private static double? Clamp(double value, double min, double max) => double.IsFinite(value) ? Math.Clamp(value, min, max) : null;
    public void Save()
    {
        if (preserveFile) return;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string temporary = path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temporary, path, true);
    }
}
