namespace Slightshot.Core;

public static class ErrorLog
{
    public const int MaximumBytes = 1_000_000;

    public static string Append(string directory, string source, Exception error, DateTimeOffset time)
    {
        Directory.CreateDirectory(directory);
        string path = Path.Combine(directory, "errors.log");
        var existing = new FileInfo(path);
        if (existing.Exists && existing.Length > MaximumBytes) File.Move(path, path + ".old", true);
        File.AppendAllText(path, $"{time:O} {source}{Environment.NewLine}{error}{Environment.NewLine}{Environment.NewLine}");
        return path;
    }
}
