using Slightshot.Core;

internal static class ExactSizeBufferPoolChecks
{
    internal static int Run()
    {
        int checks = 0;
        void Require(bool condition, string message)
        {
            if (!condition) throw new InvalidOperationException("Exact video buffers: " + message);
            checks++;
        }
        var pool = new ExactSizeBufferPool(3, 100L * 1024 * 1024);
        const int fourKBytes = 3840 * 2160 * 4;
        var first = pool.Rent(fourKBytes); var second = pool.Rent(fourKBytes); var third = pool.Rent(fourKBytes);
        byte[][] initial = [first.Pixels, second.Pixels, third.Pixels];
        Require(initial.All(pixels => pixels.Length == fourKBytes), "4K leases are exact-sized, with no 64 MiB bucket rounding");
        Require(initial.Distinct().Count() == 3, "current, lookahead and composition never alias");
        Require(pool.RetainedCount == 0 && pool.RetainedBytes == 0, "active buffers are not available for another export");
        first.Dispose(); second.Dispose(); third.Dispose();
        Require(pool.RetainedCount == 3 && pool.RetainedBytes == 3L * fourKBytes, "three 4K buffers fit below the 100 MiB retention cap");
        long before = GC.GetAllocatedBytesForCurrentThread();
        for (int repeat = 0; repeat < 20; repeat++)
        {
            using var a = pool.Rent(fourKBytes); using var b = pool.Rent(fourKBytes); using var c = pool.Rent(fourKBytes);
            Require(initial.Contains(a.Pixels) && initial.Contains(b.Pixels) && initial.Contains(c.Pixels), "repeated exports reuse the original pixel arrays");
            Require(!ReferenceEquals(a.Pixels, b.Pixels) && !ReferenceEquals(a.Pixels, c.Pixels) && !ReferenceEquals(b.Pixels, c.Pixels), "reused active roles remain distinct");
        }
        long repeatedBytes = GC.GetAllocatedBytesForCurrentThread() - before;
        Require(repeatedBytes < 4096, "twenty repeated 4K exports allocate only small lease objects, no full-frame storage");
        Console.WriteLine($"Exact export buffers: three {fourKBytes:N0}-byte arrays reused for 20 exports; {repeatedBytes:N0} B lease allocation, {pool.RetainedBytes:N0} B retained (cap 100 MiB).");

        var limited = new ExactSizeBufferPool(2, 96);
        var a32 = limited.Rent(32); var b32 = limited.Rent(32); var c32 = limited.Rent(32);
        a32.Dispose(); b32.Dispose(); c32.Dispose();
        Require(limited.RetainedCount == 2 && limited.RetainedBytes == 64, "idle buffer count is bounded under simultaneous leases");
        var exact = limited.Rent(40);
        Require(exact.Pixels.Length == 40 && !ReferenceEquals(exact.Pixels, b32.Pixels), "a different size never receives an oversized cached array");
        exact.Dispose();
        Require(limited.RetainedCount == 2 && limited.RetainedBytes == 72, "new source dimensions replace the oldest idle size");
        var withinBytes = limited.Rent(80); withinBytes.Dispose();
        Require(limited.RetainedCount == 1 && limited.RetainedBytes == 80, "byte retention cap evicts enough smaller arrays");
        var oversized = limited.Rent(128); oversized.Dispose();
        Require(limited.RetainedCount == 1 && limited.RetainedBytes == 80, "oversized source frames are usable but never retained");
        var duplicate = limited.Rent(80);
        Parallel.Invoke(duplicate.Dispose, duplicate.Dispose, duplicate.Dispose);
        Require(limited.RetainedCount == 1 && limited.RetainedBytes == 80, "concurrent duplicate disposal returns storage once");
        using var one = limited.Rent(80); using var two = limited.Rent(80);
        Require(!ReferenceEquals(one.Pixels, two.Pixels), "duplicate disposal cannot create two owners for one array");
        var disabled = new ExactSizeBufferPool(0, 0);
        using (var unused = disabled.Rent(8)) Require(unused.Pixels.Length == 8, "disabled retention still supports exact-sized work");
        Require(disabled.RetainedCount == 0 && disabled.RetainedBytes == 0, "disabled retention caches no arrays");
        try { pool.Rent(0); throw new InvalidOperationException("Empty buffer was accepted."); }
        catch (ArgumentOutOfRangeException) { checks++; }
        return checks;
    }
}
