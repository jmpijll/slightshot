using System.Globalization;

namespace Slightshot.Core;

public static class OutputNaming
{
    private const string DefaultTemplate = "Screenshot {date} at {time}";
    public static string FileName(string template, DateTimeOffset now, int width, int height)
    {
        string name = string.IsNullOrWhiteSpace(template) ? DefaultTemplate : template;
        var tokens = new Dictionary<string, string>
        {
            ["{date}"] = now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            ["{time}"] = now.ToString("HH.mm.ss", CultureInfo.InvariantCulture),
            ["{timestamp}"] = now.ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture),
            ["{width}"] = width.ToString(CultureInfo.InvariantCulture), ["{height}"] = height.ToString(CultureInfo.InvariantCulture)
        };
        foreach (var (token, value) in tokens) name = name.Replace(token, value, StringComparison.Ordinal);
        // Windows reserves these characters even when this code is tested on another OS.
        name = new string(name.Select(c => c < 32 || "<>:\"/\\|?*".Contains(c) ? '-' : c).ToArray()).Trim().TrimEnd('.');
        if (string.IsNullOrEmpty(name)) name = "Screenshot";
        var stem = name.Split('.')[0];
        if (new[] { "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9" }.Contains(stem, StringComparer.OrdinalIgnoreCase)) name = "_" + name;
        return name.Length > 180 ? name[..180].TrimEnd('.') : name;
    }
    public static string Extension(this ImageFormat format) => format switch { ImageFormat.Jpeg => "jpg", ImageFormat.Tiff => "tiff", _ => "png" };
}
