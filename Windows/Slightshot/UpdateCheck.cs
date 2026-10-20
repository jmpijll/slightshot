using System.Net.Http;
using System.Windows;
using Slightshot.Core;

namespace Slightshot;

// Runs only when the user asks; there is no background polling.
internal static class UpdateCheck
{
    internal const string Title = "Check for Updates";
    internal static HttpClient Client { get; set; } = new();
    internal static Action<string> OpenReleasePage { get; set; } = App.Open;
    internal static bool IsChecking { get; private set; }

    internal static async Task RunAsync(Window? owner)
    {
        if (IsChecking) return;
        IsChecking = true;
        try
        {
            var result = await ReleaseCheck.CheckAsync(Client, AppInfo.Version, ReleaseCheck.Timeout);
            Show(result, owner is { IsVisible: true } ? owner : null);
        }
        finally { IsChecking = false; }
    }

    private static void Show(UpdateCheckResult result, Window? owner)
    {
        switch (result)
        {
            case UpdateCheckResult.Available available:
                if (Message(owner, $"Slightshot {available.Version} is available.\n\nYou have {available.CurrentVersion}. Open the release page to download it?", MessageBoxButton.YesNo, MessageBoxImage.Information) == MessageBoxResult.Yes)
                    OpenReleasePage(available.ReleasePage.AbsoluteUri);
                break;
            case UpdateCheckResult.UpToDate upToDate:
                Message(owner, $"Slightshot {upToDate.Version} is up to date.", MessageBoxButton.OK, MessageBoxImage.Information);
                break;
            case UpdateCheckResult.Failed failed:
                if (Message(owner, $"Could not check for updates.\n\n{failed.Reason}\n\nOpen the Releases page instead?", MessageBoxButton.YesNo, MessageBoxImage.Warning) == MessageBoxResult.Yes)
                    OpenReleasePage(AppInfo.ReleaseUrl);
                break;
        }
    }

    private static MessageBoxResult Message(Window? owner, string text, MessageBoxButton buttons, MessageBoxImage image) =>
        owner == null ? MessageBox.Show(text, Title, buttons, image) : MessageBox.Show(owner, text, Title, buttons, image);
}
