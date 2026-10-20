using System.Text.Json;

namespace Slightshot.Core;

public sealed record SettingsRecovery(IReadOnlyList<string> ResetFields, string? BackupPath);
public sealed record SettingsRead<T>(T Value, SettingsRecovery? Recovery);

public static class SettingsFile
{
    public static SettingsRead<T> Read<T>(string path, DateTime now, Func<object, bool>? accept = null) where T : class, new()
    {
        try { return new(File.Exists(path) ? JsonSerializer.Deserialize<T>(File.ReadAllText(path)) ?? new() : new(), null); }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException) { return new(new(), null); }
    }
}
