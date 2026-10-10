namespace Slightshot.Core;

// Exact-sized native sample storage for one recording. A frame stays rented until the
// native media sample signals Processed; closing never reclaims a live frame.
public sealed class RecordingFrameBuffers(int byteCount) : IDisposable
{
    private const int Limit = 4;
    private readonly int byteCount = byteCount > 0 ? byteCount : throw new ArgumentOutOfRangeException(nameof(byteCount));
    private readonly object sync = new();
    private readonly Queue<byte[]> available = new(Limit);
    private TaskCompletionSource changed = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private int allocated;
    private bool closed;

    public async ValueTask<RecordingFrame> RentAsync(CancellationToken cancellation)
    {
        while (true)
        {
            cancellation.ThrowIfCancellationRequested();
            Task wait;
            lock (sync)
            {
                ObjectDisposedException.ThrowIf(closed, this);
                if (available.TryDequeue(out var pixels)) return new RecordingFrame(this, pixels);
                if (allocated < Limit)
                {
                    pixels = new byte[byteCount];
                    allocated++;
                    return new RecordingFrame(this, pixels);
                }
                wait = changed.Task;
            }
            await wait.WaitAsync(cancellation).ConfigureAwait(false);
        }
    }

    internal void Return(byte[] pixels)
    {
        lock (sync)
        {
            if (closed) return;
            available.Enqueue(pixels);
            WakeWaiters();
        }
    }

    public void Dispose()
    {
        lock (sync)
        {
            if (closed) return;
            closed = true;
            available.Clear();
            WakeWaiters();
        }
    }

    private void WakeWaiters()
    {
        var previous = changed;
        changed = new(TaskCreationOptions.RunContinuationsAsynchronously);
        previous.TrySetResult();
    }
}

public sealed class RecordingFrame : IDisposable
{
    private RecordingFrameBuffers? owner;
    public byte[] Pixels { get; }

    internal RecordingFrame(RecordingFrameBuffers owner, byte[] pixels)
    {
        this.owner = owner; Pixels = pixels;
    }

    public void Dispose() => Interlocked.Exchange(ref owner, null)?.Return(Pixels);
}
