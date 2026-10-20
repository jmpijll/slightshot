namespace Slightshot.Core;

// Matches the installer's RunEntryMatches: a quoted executable path without arguments.
public static class LaunchAtLogin
{
    public static string Command(string executable) => $"\"{executable}\"";
    public static bool Targets(string? command, string executable) =>
        command != null && string.Equals(command.Trim().Trim('"'), executable, StringComparison.OrdinalIgnoreCase);
}
