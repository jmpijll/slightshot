using System.IO.Pipes;
using System.Text;

namespace Slightshot.Core;

public enum LaunchCommand { CaptureArea, SaveFullScreen, CopyFullScreen }

public static class LaunchArguments
{
    private static readonly (string Argument, LaunchCommand Command)[] Commands =
        [("--capture-area", LaunchCommand.CaptureArea), ("--capture-full", LaunchCommand.SaveFullScreen), ("--copy-full", LaunchCommand.CopyFullScreen)];

    /// No arguments is a valid launch without a command.
    public static bool TryParse(IReadOnlyList<string> arguments, out LaunchCommand? command)
    {
        command = null;
        if (arguments.Count == 0) return true;
        if (arguments.Count > 1) return false;
        foreach (var entry in Commands)
            if (entry.Argument == arguments[0]) { command = entry.Command; return true; }
        return false;
    }

    public static string Format(LaunchCommand command) => Commands.Single(entry => entry.Command == command).Argument;
}

/// Receives launch commands from later launches of the same user. The pipe only
/// admits the current user; acceptClient decides whether a connected client, for
/// example one from another logon session, may deliver a command. Each connection
/// carries one argument line and is answered with '1' or '0'.
public sealed class InstanceChannel : IDisposable
{
    private const int MaximumLineBytes = 64;
    private static readonly TimeSpan ClientDeadline = TimeSpan.FromSeconds(2);
    private readonly CancellationTokenSource stopping = new();
    private readonly Task listening;

    public InstanceChannel(string pipeName, Func<NamedPipeServerStream, bool> acceptClient, Action<LaunchCommand> received) =>
        listening = Task.Run(() => ListenAsync(pipeName, acceptClient, received, stopping.Token));

    public static async Task<bool> SendAsync(string pipeName, LaunchCommand command, TimeSpan timeout)
    {
        using var deadline = new CancellationTokenSource(timeout);
        try
        {
            using var client = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            await client.ConnectAsync(deadline.Token);
            await client.WriteAsync(Encoding.UTF8.GetBytes(LaunchArguments.Format(command) + "\n"), deadline.Token);
            await client.FlushAsync(deadline.Token);
            var reply = new byte[1];
            return await client.ReadAsync(reply, deadline.Token) == 1 && reply[0] == (byte)'1';
        }
        catch (Exception ex) when (ex is IOException or TimeoutException or OperationCanceledException or UnauthorizedAccessException) { return false; }
    }

    private static async Task ListenAsync(string pipeName, Func<NamedPipeServerStream, bool> acceptClient, Action<LaunchCommand> received, CancellationToken stop)
    {
        NamedPipeServerStream? server = null;
        try
        {
            while (!stop.IsCancellationRequested)
            {
                try
                {
                    server ??= Create(pipeName);
                    await server.WaitForConnectionAsync(stop);
                    // Open the next instance before answering so a later launch
                    // always finds a listener, then hand this connection off.
                    var connected = server;
                    server = null;
                    try { server = Create(pipeName); }
                    finally { _ = AnswerAsync(connected, acceptClient, received, stop); }
                }
                catch (OperationCanceledException) when (stop.IsCancellationRequested) { return; }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    server?.Dispose(); server = null;
                    await Task.Delay(250, CancellationToken.None);
                }
            }
        }
        finally { server?.Dispose(); }
    }

    // CurrentUserOnly also stops other users adding instances of this name.
    private static NamedPipeServerStream Create(string pipeName) => new(pipeName, PipeDirection.InOut, NamedPipeServerStream.MaxAllowedServerInstances,
        PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);

    private static async Task AnswerAsync(NamedPipeServerStream server, Func<NamedPipeServerStream, bool> acceptClient, Action<LaunchCommand> received, CancellationToken stop)
    {
        using (server)
        using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(stop))
        {
            deadline.CancelAfter(ClientDeadline);
            try
            {
                LaunchCommand? command = acceptClient(server) ? await ReadCommandAsync(server, deadline.Token) : null;
                if (command is { } accepted) received(accepted);
                await server.WriteAsync(new[] { (byte)(command == null ? '0' : '1') }, deadline.Token);
                await server.FlushAsync(deadline.Token);
            }
            catch (Exception ex) when (ex is IOException or OperationCanceledException) { }
        }
    }

    private static async Task<LaunchCommand?> ReadCommandAsync(Stream stream, CancellationToken token)
    {
        var buffer = new byte[MaximumLineBytes];
        int length = 0;
        while (length < buffer.Length)
        {
            int read = await stream.ReadAsync(buffer.AsMemory(length, 1), token);
            if (read == 0) return null;
            if (buffer[length] == (byte)'\n')
                return LaunchArguments.TryParse([Encoding.UTF8.GetString(buffer, 0, length)], out var command) ? command : null;
            length++;
        }
        return null;
    }

    public void Dispose()
    {
        stopping.Cancel();
        try { listening.Wait(TimeSpan.FromSeconds(2)); } catch (AggregateException) { }
        stopping.Dispose();
    }
}
