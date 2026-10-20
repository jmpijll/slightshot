using System.Text;

namespace Slightshot.Core;

public static class ErrorLog
{
    public const int MaximumBytes = 1_000_000;
    private const int MaximumEntryChars = 32_000;

    public static string Append(string directory, string source, Exception error, DateTimeOffset time)
    {
        Directory.CreateDirectory(directory);
        string path = Path.Combine(directory, "errors.log");
        string details = error.ToString();
        if (details.Length > MaximumEntryChars) details = details[..MaximumEntryChars] + " [truncated]";
        string entry = $"{time:O} {source}{Environment.NewLine}{details}{Environment.NewLine}{Environment.NewLine}";
        var existing = new FileInfo(path);
        if (existing.Exists && existing.Length + Encoding.UTF8.GetByteCount(entry) > MaximumBytes) File.Move(path, path + ".old", true);
        File.AppendAllText(path, entry);
        return path;
    }
}
