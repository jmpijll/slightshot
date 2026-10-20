namespace Slightshot.Core;

public static class LaunchAtLogin
{
    public static string Command(string executable) => $"\"{executable}\"";
    public static bool Targets(string? command, string executable) => command != null;
}
