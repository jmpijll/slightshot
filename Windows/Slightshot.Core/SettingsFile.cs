using System.Reflection;
using System.Text.Json;

namespace Slightshot.Core;

// ResetFields is empty when the whole file was unusable. A null BackupPath means
// the original could not be kept, so the caller must not replace the file.
public sealed record SettingsRecovery(IReadOnlyList<string> ResetFields, string? BackupPath);
public sealed record SettingsRead<T>(T Value, SettingsRecovery? Recovery);

public static class SettingsFile
{
    // repair returns the value to keep, or null to use the default; any change is reported.
    public static SettingsRead<T> Read<T>(string path, DateTime now, Func<string, object, object?>? repair = null) where T : class, new()
    {
        if (!File.Exists(path)) return new(new(), null);
        byte[] bytes;
        try { bytes = File.ReadAllBytes(path); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return new(new(), new([], null)); }
        var value = new T();
        var reset = new List<string>();
        try
        {
            using var document = JsonDocument.Parse(bytes.AsMemory(bytes.AsSpan().StartsWith((byte[])[0xEF, 0xBB, 0xBF]) ? 3 : 0));
            if (document.RootElement.ValueKind != JsonValueKind.Object) return new(new(), new([], Backup(path, bytes, now)));
            foreach (var property in typeof(T).GetProperties(BindingFlags.Public | BindingFlags.Instance))
            {
                if (!property.CanWrite || !document.RootElement.TryGetProperty(property.Name, out var element)) continue;
                object? field;
                try { field = element.Deserialize(property.PropertyType); }
                catch (Exception ex) when (ex is JsonException or NotSupportedException) { field = null; }
                if (field is Enum && !Enum.IsDefined(property.PropertyType, field)) field = null;
                object? kept = field == null || repair == null ? field : repair(property.Name, field);
                if (kept != null) property.SetValue(value, kept);
                if (kept == null || !Equals(kept, field)) reset.Add(property.Name);
            }
        }
        catch (JsonException) { return new(new(), new([], Backup(path, bytes, now))); }
        return new(value, reset.Count == 0 ? null : new(reset, Backup(path, bytes, now)));
    }

    private static string? Backup(string path, byte[] bytes, DateTime now)
    {
        string stem = Path.Combine(Path.GetDirectoryName(path)!, $"{Path.GetFileNameWithoutExtension(path)}.corrupt-{now:yyyyMMdd-HHmmss}");
        try
        {
            for (int attempt = 1; ; attempt++)
            {
                string candidate = $"{stem}{(attempt == 1 ? "" : $"-{attempt}")}{Path.GetExtension(path)}";
                if (File.Exists(candidate)) continue;
                using var stream = new FileStream(candidate, FileMode.CreateNew, FileAccess.Write);
                stream.Write(bytes);
                return candidate;
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return null; }
    }
}
