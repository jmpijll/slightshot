using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Slightshot.Core;

namespace Slightshot;

// The fixture owns the production session mutex and pipe, then starts the real
// executable as later launches. Fixture exceptions go through the production
// handlers with a real overlay open. No user settings or logs are written.
internal static class InstanceSmokeTest
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    internal static async Task RunAsync(App app, string directory)
    {
        Directory.CreateDirectory(directory);
        string sourceCommit = Environment.GetEnvironmentVariable("SLIGHTSHOT_SOURCE_COMMIT")
            ?? Environment.GetEnvironmentVariable("GITHUB_SHA") ?? "local source commit not supplied";
        var checks = new List<string>();
        var launches = new List<object>();
        var received = new List<LaunchCommand>();
        using (var mutex = new Mutex(true, App.InstanceMutexName, out bool owns))
        {
            Require(owns, "no other Slightshot instance owns the session mutex");
            try
            {
                using var channel = new InstanceChannel(App.InstancePipeName(), command => { lock (received) received.Add(command); });
                (string[] Arguments, LaunchCommand? Expected, int ExitCode)[] cases =
                [
                    ([], LaunchCommand.CaptureArea, 0), (["--capture-area"], LaunchCommand.CaptureArea, 0),
                    (["--capture-full"], LaunchCommand.SaveFullScreen, 0), (["--copy-full"], LaunchCommand.CopyFullScreen, 0), (["--unknown"], null, 2),
                ];
                foreach (var (arguments, expected, exitCode) in cases)
                {
                    int before;
                    lock (received) before = received.Count;
                    var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false };
                    foreach (string argument in arguments) start.ArgumentList.Add(argument);
                    var timer = Stopwatch.StartNew();
                    using var process = Process.Start(start)!;
                    using (var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(30)))
                    {
                        try { await process.WaitForExitAsync(deadline.Token); }
                        catch (OperationCanceledException) { process.Kill(); Require(false, $"second launch [{string.Join(' ', arguments)}] exits within 30 seconds"); }
                    }
                    LaunchCommand[] delivered;
                    lock (received) delivered = received.Skip(before).ToArray();
                    string label = arguments.Length == 0 ? "(no arguments)" : string.Join(' ', arguments);
                    launches.Add(new { arguments = label, exitCode = process.ExitCode, milliseconds = timer.ElapsedMilliseconds, delivered = delivered.Select(command => command.ToString()) });
                    Require(process.ExitCode == exitCode && delivered.SequenceEqual(expected is { } command ? [command] : []),
                        $"second launch {label} exits {exitCode} and delivers {expected?.ToString() ?? "nothing"}: exit {process.ExitCode}, delivered [{string.Join(", ", delivered)}]");
                }
            }
            finally { mutex.ReleaseMutex(); }
        }
        checks.Add("Real second launches forward no arguments and --capture-area as CaptureArea, --capture-full as SaveFullScreen and --copy-full as CopyFullScreen, then exit 0; an unknown argument exits 2 without a command.");

        string logDirectory = Path.Combine(directory, "error-log");
        var reports = new List<string>();
        int reportsFinished = 0;
        app.InstallErrorHandlers(logDirectory, message =>
        {
            reports.Add(message);
            // Pump the dispatcher like an open message box while a second failure arrives.
            var frame = new DispatcherFrame();
            app.Dispatcher.BeginInvoke(() => throw new InvalidOperationException("second fixture failure while the message is open"));
            app.Dispatcher.BeginInvoke(() => frame.Continue = false);
            Dispatcher.PushFrame(frame);
            reportsFinished++;
        }, () => true);
        var overlays = new OverlayCoordinator(new Settings { PlaySound = false }, (_, _) => true, () => { }, (_, _) => { });
        typeof(App).GetField("overlays", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(app, overlays);
        var image = BitmapSource.Create(64, 64, 96, 96, PixelFormats.Bgra32, null, new byte[64 * 64 * 4], 64 * 4);
        Require(overlays.PresentClipboardImage(image) && overlays.IsBusy && overlays.Windows.Single().IsVisible, "fixture overlay is open before the failure");
        _ = app.Dispatcher.BeginInvoke(() => throw new InvalidOperationException("fixture failure in the capture overlay"));
        for (int attempt = 0; attempt < 50 && reportsFinished == 0; attempt++) await Task.Delay(100);
        string logPath = Path.Combine(logDirectory, "errors.log");
        string log = File.Exists(logPath) ? File.ReadAllText(logPath) : "";
        Require(reports.Count == 1 && reports[0].Contains("closed the capture") && reports[0].Contains(logPath), $"one message names the log after a UI-thread failure: [{string.Join(" | ", reports)}]");
        Require(log.Contains("fixture failure in the capture overlay") && log.Contains("second fixture failure while the message is open"), "both UI-thread failures are logged");
        Require(!overlays.IsBusy && overlays.Windows.Count == 0, "the failed overlay is closed");
        Require(await app.Dispatcher.InvokeAsync(() => true), "the dispatcher keeps running after the failure");
        checks.Add("A UI-thread exception with a real overlay open is logged, closes the overlay and shows one message; a second exception raised while that message pumps is logged without another message; the dispatcher keeps running.");

        for (int attempt = 0; attempt < 20 && !log.Contains("unobserved fixture failure"); attempt++)
        {
            AbandonFaultedTask();
            await Task.Delay(100);
            GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect();
            await Task.Delay(100);
            log = File.ReadAllText(logPath);
        }
        Require(log.Contains("Unobserved task exception") && log.Contains("unobserved fixture failure"), "an unobserved task exception is logged");
        Require(reports.Count == 1, "background failures do not show a message");
        checks.Add("An unobserved task exception is logged without a message.");

        File.WriteAllText(Path.Combine(directory, "instance-validation.json"), JsonSerializer.Serialize(new
        {
            platform = "Windows / native WPF app and real second-launch processes",
            sourceCommit, source = "Automated fixture: this process owns the production mutex and pipe; the real executable is started as later launches. Exceptions are fixture throws.",
            launches, messages = reports, errorLog = log.Split(Environment.NewLine).Where(line => line.Contains("fixture failure") || line.Contains(" UI thread") || line.Contains("Unobserved task exception")).ToArray(), checks
        }, JsonOptions));
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static void AbandonFaultedTask() => _ = Task.Run(() => throw new InvalidOperationException("unobserved fixture failure"));

    private static void Require(bool condition, string check) { if (!condition) throw new InvalidOperationException("Windows instance smoke test failed: " + check); }
}
