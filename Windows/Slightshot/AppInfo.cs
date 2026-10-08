using System.Reflection;

namespace Slightshot;

internal static class AppInfo
{
    internal const string ReleaseUrl = "https://github.com/jmpijll/slightshot/releases/latest";
    internal static string Version { get; } = (typeof(App).Assembly
        .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
        ?? typeof(App).Assembly.GetName().Version?.ToString(3) ?? "Unknown").Split('+')[0];
    internal static string AboutText => $"Slightshot {Version} for Windows\n\nAn open-source screenshot and screen recording app for Windows.\n\ngithub.com/jmpijll/slightshot";
}
