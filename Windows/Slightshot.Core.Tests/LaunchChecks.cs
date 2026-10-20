using System.IO.Pipes;
using System.Text;
using Slightshot.Core;

internal static class LaunchChecks
{
    internal static int Run()
    {
        int checks = 0;
        void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); checks++; }

        const uint Alt = 1, Control = 2, Shift = 4, Win = 8, A = 0x41, F13 = 0x7c;
        Require(HotKeyRules.IsValid(HotKeyRules.PrintScreen, 0), "Print Screen alone is a valid shortcut");
        Require(HotKeyRules.IsValid(HotKeyRules.PrintScreen, Control | Shift), "Print Screen with modifiers stays valid");
        Require(!HotKeyRules.IsValid(A, 0) && !HotKeyRules.IsValid(F13, 0), "other keys without a modifier are rejected");
        Require(HotKeyRules.IsValid(A, Control | Shift) && HotKeyRules.IsValid(F13, Win) && HotKeyRules.IsValid(F13, Alt | Control | Shift | Win), "modified keys are valid");
        Require(!HotKeyRules.IsValid(A, Control | 0x4000) && !HotKeyRules.IsValid(0x100, Control), "unknown modifier bits and out-of-range keys are rejected");
        Require(HotKeyRules.IsValid(0, 0), "an empty shortcut is valid");

        Require(LaunchArguments.TryParse([], out var none) && none == null, "no arguments launch without a command");
        Require(LaunchArguments.TryParse(["--capture-area"], out var area) && area == LaunchCommand.CaptureArea, "--capture-area parses");
        Require(LaunchArguments.TryParse(["--capture-full"], out var save) && save == LaunchCommand.SaveFullScreen, "--capture-full parses");
        Require(LaunchArguments.TryParse(["--copy-full"], out var copy) && copy == LaunchCommand.CopyFullScreen, "--copy-full parses");
        foreach (string[] arguments in new[] { new[] { "--CAPTURE-AREA" }, ["capture-area"], ["--capture-area", "--copy-full"], ["--unknown"], [""] })
            Require(!LaunchArguments.TryParse(arguments, out _), $"[{string.Join(", ", arguments)}] is rejected");
        foreach (var command in Enum.GetValues<LaunchCommand>())
            Require(LaunchArguments.TryParse([LaunchArguments.Format(command)], out var roundTrip) && roundTrip == command, $"{command} round-trips through its argument");

        checks += ForwardingChecks().GetAwaiter().GetResult();

        string directory = Path.Combine(Path.GetTempPath(), "slightshot-error-log-" + Guid.NewGuid().ToString("N"));
        try
        {
            var time = new DateTimeOffset(2026, 10, 20, 12, 0, 0, TimeSpan.Zero);
            string path = ErrorLog.Append(directory, "UI thread", new InvalidOperationException("first failure"), time);
            ErrorLog.Append(directory, "Background task", new IOException("second failure"), time);
            string text = File.ReadAllText(path);
            Require(Path.GetDirectoryName(path) == directory && text.Contains("2026-10-20T12:00:00.0000000+00:00 UI thread") && text.Contains("InvalidOperationException: first failure") && text.Contains("IOException: second failure"), "errors are appended with time, source and exception");
            File.WriteAllText(path, new string('x', ErrorLog.MaximumBytes + 1));
            ErrorLog.Append(directory, "UI thread", new InvalidOperationException("after rotation"), time);
            Require(new FileInfo(path).Length < ErrorLog.MaximumBytes && File.ReadAllText(path).Contains("after rotation") && new FileInfo(path + ".old").Length > ErrorLog.MaximumBytes, "a full log is rotated before appending");
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
        return checks;
    }

    private static async Task<int> ForwardingChecks()
    {
        int checks = 0;
        void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); checks++; }
        string name = "ss-" + Guid.NewGuid().ToString("N")[..12];
        var timeout = TimeSpan.FromSeconds(5);
        Require(!await InstanceChannel.SendAsync(name, LaunchCommand.CaptureArea, TimeSpan.FromMilliseconds(300)), "forwarding without a running instance fails within its timeout");

        var received = new List<LaunchCommand>();
        var arrived = new SemaphoreSlim(0);
        using (new InstanceChannel(name, command => { lock (received) received.Add(command); arrived.Release(); }))
        {
            foreach (var command in new[] { LaunchCommand.CaptureArea, LaunchCommand.SaveFullScreen, LaunchCommand.CopyFullScreen })
            {
                Require(await InstanceChannel.SendAsync(name, command, timeout), $"{command} is acknowledged");
                Require(await arrived.WaitAsync(timeout), $"{command} reaches the running instance");
            }
            Require(received.SequenceEqual([LaunchCommand.CaptureArea, LaunchCommand.SaveFullScreen, LaunchCommand.CopyFullScreen]), "commands arrive once, in order");

            using (var client = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly))
            {
                await client.ConnectAsync(5000);
                await client.WriteAsync(Encoding.UTF8.GetBytes("--delete-everything\n"));
                var reply = new byte[1];
                Require(await client.ReadAsync(reply) == 1 && reply[0] == (byte)'0', "an unknown command is refused");
            }
            using (var silent = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly))
            {
                await silent.ConnectAsync(5000);
                Require(await InstanceChannel.SendAsync(name, LaunchCommand.CopyFullScreen, timeout), "a silent client cannot block later commands");
            }
            Require(await arrived.WaitAsync(timeout) && received.Count == 4 && received[^1] == LaunchCommand.CopyFullScreen, "only valid commands are delivered");
        }
        Require(!await InstanceChannel.SendAsync(name, LaunchCommand.CaptureArea, TimeSpan.FromMilliseconds(300)), "a disposed channel stops accepting commands");
        return checks;
    }
}
