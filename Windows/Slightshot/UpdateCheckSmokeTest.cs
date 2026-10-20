using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;
using System.Windows.Threading;
using Slightshot.Core;
using Forms = System.Windows.Forms;
using Native = Slightshot.AppTextSmokeTest;

namespace Slightshot;

// Drives the production tray item and Settings button against a stubbed
// GitHub response, so no network request leaves the CI runner. The native
// MessageBoxes are captured and answered by automated button clicks.
internal static class UpdateCheckSmokeTest
{
    private const string Page = "https://github.com/jmpijll/slightshot/releases/tag/";

    internal static async Task RunAsync(string directory, List<string> checks)
    {
        string version = AppInfo.Version;
        Require(ReleaseVersion.TryParse(version, out var current, out _), "running executable has a release version");
        string next = new ReleaseVersion(current.Major, current.Minor + 1, 0).ToString();
        var handler = new FixtureHandler();
        var opened = new List<string>();
        var (client, open) = (UpdateCheck.Client, UpdateCheck.OpenReleasePage);
        UpdateCheck.Client = new HttpClient(handler); UpdateCheck.OpenReleasePage = opened.Add;
        var app = (App)System.Windows.Application.Current;
        using var menu = app.CreateCaptureMenu();
        try
        {
            var tray = menu.Items.OfType<Forms.ToolStripMenuItem>().Single(item => item.Text == "Check for Updates…");
            menu.Show(100, 120);
            await Task.Delay(300);
            NativeMethods.DwmFlush();
            SaveScreen(menu.Bounds, Path.Combine(directory, "update-tray-menu.png"));
            menu.Close();

            handler.Respond = () => Task.FromResult(Release(version));
            await Answer(() => tray.PerformClick(), $"Slightshot {version} is up to date.", ["OK"], "OK", Path.Combine(directory, "update-up-to-date.png"));
            checks.Add($"Fixture GitHub release v{version}: production tray Check for Updates… showed \"Slightshot {version} is up to date.\" in a native MessageBox; OK clicked automatically.");

            var preferences = new SettingsWindow(new Settings { PlaySound = false }, false);
            try
            {
                preferences.Show(); preferences.Activate();
                await preferences.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.Loaded);
                await Task.Delay(250);
                var button = Native.Descendants((DependencyObject)preferences.Content).OfType<Button>().Single(b => Equals(b.Content, "Check for Updates…"));
                var gate = new TaskCompletionSource();
                handler.Respond = async () => { await gate.Task; return Release(next); };
                button.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
                await Task.Delay(250);
                Require(!button.IsEnabled && Equals(button.Content, "Checking…") && UpdateCheck.IsChecking, "Settings shows Checking… while the request is pending");
                Native.CaptureWindow(new WindowInteropHelper(preferences).Handle, Path.Combine(directory, "update-settings-checking.png"));
                tray.PerformClick();
                await Task.Delay(250);
                Require(handler.Requests.Count == 2, "a click during a pending check sends no second request");
                string text = $"Slightshot {next} is available.\n\nYou have {version}. Open the release page to download it?";
                await Answer(gate.SetResult, text, ["Yes", "No"], "Yes", Path.Combine(directory, "update-available.png"));
                Require(opened.SequenceEqual([Page + "v" + next]), "Yes opens the fixture release's html_url");
                var restored = Stopwatch.StartNew();
                while (!button.IsEnabled && restored.Elapsed < TimeSpan.FromSeconds(5)) await Task.Delay(50);
                Require(button.IsEnabled && Equals(button.Content, "Check for Updates…") && !UpdateCheck.IsChecking, "Settings button is restored after the dialog closes");
            }
            finally { preferences.Close(); }
            checks.Add($"Fixture GitHub release v{next}: production Settings Check for Updates… showed Checking… while the stubbed request was held, ignored a tray click meanwhile, then showed \"Slightshot {next} is available.\"; Yes clicked automatically and the release's html_url was passed to the opener.");

            handler.Respond = () => throw new HttpRequestException("Fixture network failure");
            await Answer(() => tray.PerformClick(),
                "Could not check for updates.\n\nGitHub could not be reached. Check your internet connection and try again.\n\nOpen the Releases page instead?",
                ["Yes", "No"], "No", Path.Combine(directory, "update-network-failure.png"));
            Require(opened.Count == 1, "No on the failure dialog opens nothing");
            checks.Add("Fixture network failure: production tray Check for Updates… showed the could-not-be-reached message with a Releases fallback; No clicked automatically.");

            foreach (var request in handler.Requests)
                Require(request.Method == HttpMethod.Get && request.RequestUri == ReleaseCheck.LatestRelease
                    && request.Headers.UserAgent.ToString() == $"Slightshot/{version}" && request.Headers.Authorization == null && request.Content == null,
                    "each request is an unauthenticated GET to the latest-release endpoint with a Slightshot User-Agent");
            Require(handler.Requests.Count == 3, "three clicks that started checks sent exactly three requests");
            checks.Add($"Stub handler received exactly {handler.Requests.Count} GET requests to {ReleaseCheck.LatestRelease}, each with User-Agent Slightshot/{version}, no Authorization header and no body.");
        }
        finally { UpdateCheck.Client = client; UpdateCheck.OpenReleasePage = open; }
    }

    private static async Task Answer(Action trigger, string text, string[] buttons, string click, string path)
    {
        uint processId = (uint)Environment.ProcessId;
        var answer = Task.Run(async () =>
        {
            var timeout = Stopwatch.StartNew();
            IntPtr dialog = IntPtr.Zero;
            try
            {
                while (dialog == IntPtr.Zero && timeout.Elapsed < TimeSpan.FromSeconds(10))
                {
                    dialog = Native.FindDialog(processId, UpdateCheck.Title);
                    if (dialog == IntPtr.Zero) await Task.Delay(50);
                }
                Require(dialog != IntPtr.Zero, $"update dialog opens within ten seconds: {text}");
                await Task.Delay(250);
                var controls = new List<(IntPtr Handle, string Class, string Text, bool Visible)>();
                Native.EnumChildWindows(dialog, (child, _) => { controls.Add((child, Native.ClassName(child), Native.WindowText(child), Native.IsWindowVisible(child))); return true; }, IntPtr.Zero);
                Require(controls.Any(control => control.Class == "Static" && control.Text.Replace("\r\n", "\n") == text), $"update dialog shows: {text}");
                var visible = controls.Where(control => control.Visible && control.Class.Equals("Button", StringComparison.OrdinalIgnoreCase))
                    .ToDictionary(control => control.Text.Replace("&", "").Trim(), control => control.Handle);
                Require(visible.Keys.Order().SequenceEqual(buttons.Order()), $"update dialog offers {string.Join("/", buttons)}");
                Native.CaptureWindow(dialog, path);
                Require(Native.PostMessage(visible[click], 0x00F5, IntPtr.Zero, IntPtr.Zero), $"automated click reaches {click}");
                while (Native.IsWindow(dialog) && timeout.Elapsed < TimeSpan.FromSeconds(10)) await Task.Delay(50);
                Require(!Native.IsWindow(dialog), "update dialog closes after the automated click");
            }
            finally { if (dialog != IntPtr.Zero && Native.IsWindow(dialog)) Native.PostMessage(dialog, 0x0010, IntPtr.Zero, IntPtr.Zero); }
        });
        trigger();
        await answer;
        var settled = Stopwatch.StartNew();
        while (UpdateCheck.IsChecking && settled.Elapsed < TimeSpan.FromSeconds(5)) await Task.Delay(50);
        Require(!UpdateCheck.IsChecking, "update check finishes after its dialog closes");
    }

    private static HttpResponseMessage Release(string version) => new(HttpStatusCode.OK)
    {
        Content = new StringContent($$"""{"tag_name":"v{{version}}","html_url":"{{Page}}v{{version}}","prerelease":false}""", Encoding.UTF8, "application/json")
    };

    private static void SaveScreen(System.Drawing.Rectangle bounds, string path)
    {
        using var bitmap = new System.Drawing.Bitmap(bounds.Width, bounds.Height);
        using (var graphics = System.Drawing.Graphics.FromImage(bitmap)) graphics.CopyFromScreen(bounds.Location, System.Drawing.Point.Empty, bounds.Size);
        bitmap.Save(path, System.Drawing.Imaging.ImageFormat.Png);
    }

    private static void Require(bool condition, string check) { if (!condition) throw new InvalidOperationException($"Update check smoke test failed: {check}"); }

    private sealed class FixtureHandler : HttpMessageHandler
    {
        internal List<HttpRequestMessage> Requests { get; } = [];
        internal Func<Task<HttpResponseMessage>> Respond { get; set; } = () => throw new InvalidOperationException("no fixture response");
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests.Add(request);
            return Respond();
        }
    }
}
