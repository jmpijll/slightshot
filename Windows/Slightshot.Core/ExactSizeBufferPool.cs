namespace Slightshot.Core;

// Reuse exact pixel lengths across exports. Only idle buffers count toward the
// retention limits; a lease never shares storage with another active request.
public sealed class ExactSizeBufferPool
{
    private readonly int maximumCount;
    private readonly long maximumBytes;
    private readonly object sync = new();
    private readonly List<byte[]> available = [];
    private long retainedBytes;
    internal int RetainedCount { get { lock (sync) return available.Count; } }
    internal long RetainedBytes { get { lock (sync) return retainedBytes; } }

    public ExactSizeBufferPool(int maximumCount, long maximumBytes)
    {
        if (maximumCount < 0) throw new ArgumentOutOfRangeException(nameof(maximumCount));
        if (maximumBytes < 0) throw new ArgumentOutOfRangeException(nameof(maximumBytes));
        this.maximumCount = maximumCount; this.maximumBytes = maximumBytes;
    }
    public BufferLease Rent(int byteCount)
    {
        if (byteCount <= 0) throw new ArgumentOutOfRangeException(nameof(byteCount));
        lock (sync)
        {
            for (int index = available.Count - 1; index >= 0; index--)
            {
                byte[] pixels = available[index];
                if (pixels.Length != byteCount) continue;
                available.RemoveAt(index); retainedBytes -= pixels.Length;
                return new(this, pixels);
            }
        }
        return new(this, new byte[byteCount]);
    }
    private void Return(byte[] pixels)
    {
        if (maximumCount == 0 || pixels.LongLength > maximumBytes) return;
        lock (sync)
        {
            // Prefer the latest source sizes when recordings change dimensions.
            while (available.Count >= maximumCount || retainedBytes + pixels.LongLength > maximumBytes)
            {
                retainedBytes -= available[0].Length; available.RemoveAt(0);
            }
            available.Add(pixels); retainedBytes += pixels.Length;
        }
    }
    public sealed class BufferLease : IDisposable
    {
        private ExactSizeBufferPool? owner;
        public byte[] Pixels { get; }
        internal BufferLease(ExactSizeBufferPool owner, byte[] pixels) { this.owner = owner; Pixels = pixels; }
        public void Dispose() => Interlocked.Exchange(ref owner, null)?.Return(Pixels);
    }
}
