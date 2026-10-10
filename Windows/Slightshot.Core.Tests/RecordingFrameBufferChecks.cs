using Slightshot.Core;

internal static class RecordingFrameBufferChecks
{
    internal static async Task<int> RunAsync()
    {
        int checks = 0;
        void Require(bool value, string message)
        {
            if (!value) throw new InvalidOperationException(message);
            checks++;
        }

        // Returning a frame too early would let a later capture overwrite pixels
        // still owned by the encoder; exceeding the cap would hide that bug.
        using (var buffers = new RecordingFrameBuffers(16))
        {
            var frames = new List<RecordingFrame>();
            for (int index = 0; index < 4; index++)
            {
                var frame = await buffers.RentAsync(CancellationToken.None);
                frame.Pixels.AsSpan().Fill((byte)(index + 1));
                frames.Add(frame);
            }
            Require(frames.All(frame => frame.Pixels.Length == 16), "frames have the exact native sample byte count");
            Require(frames.Select(frame => frame.Pixels).Distinct().Count() == 4, "outstanding frames never share pixel storage");
            Task<RecordingFrame> pending = buffers.RentAsync(CancellationToken.None).AsTask();
            Require(!pending.IsCompleted, "a fifth live frame waits instead of allocating a backlog");
            frames[1].Dispose();
            using var reused = await pending.WaitAsync(TimeSpan.FromSeconds(2));
            Require(ReferenceEquals(frames[1].Pixels, reused.Pixels), "only a released frame becomes reusable");
            reused.Pixels.AsSpan().Fill(99);
            Require(frames[0].Pixels.All(value => value == 1) && frames[2].Pixels.All(value => value == 3) && frames[3].Pixels.All(value => value == 4), "new capture preserves all other outstanding pixels");
            // A duplicate media completion must not put a still-live buffer back.
            frames[1].Dispose();
            using var cancellation = new CancellationTokenSource();
            Task<RecordingFrame> duplicate = buffers.RentAsync(cancellation.Token).AsTask();
            Require(!duplicate.IsCompleted, "duplicate release cannot issue one array to two live frames");
            cancellation.Cancel();
            await ExpectCancellationAsync(duplicate);
            checks++;
            foreach (var frame in frames) frame.Dispose();
        }

        using (var buffers = new RecordingFrameBuffers(4))
        {
            var frames = new List<RecordingFrame>();
            for (int index = 0; index < 4; index++) frames.Add(await buffers.RentAsync(CancellationToken.None));
            using var cancellation = new CancellationTokenSource();
            Task<RecordingFrame> pending = buffers.RentAsync(cancellation.Token).AsTask();
            cancellation.Cancel();
            await ExpectCancellationAsync(pending);
            checks++;
            frames[0].Dispose();
            using var recovered = await buffers.RentAsync(CancellationToken.None).AsTask().WaitAsync(TimeSpan.FromSeconds(2));
            Require(ReferenceEquals(frames[0].Pixels, recovered.Pixels), "a cancelled wait does not consume a later released frame");
            foreach (var frame in frames) frame.Dispose();
        }

        var closing = new RecordingFrameBuffers(4);
        var outstanding = new List<RecordingFrame>();
        for (int index = 0; index < 4; index++) outstanding.Add(await closing.RentAsync(CancellationToken.None));
        outstanding[0].Pixels.AsSpan().Fill(71);
        Task<RecordingFrame> closedWait = closing.RentAsync(CancellationToken.None).AsTask();
        closing.Dispose();
        await ExpectDisposedAsync(closedWait);
        checks++;
        Require(outstanding[0].Pixels.All(value => value == 71), "closing leaves native-owned pixels intact");
        foreach (var frame in outstanding) { frame.Dispose(); frame.Dispose(); }
        closing.Dispose();
        await ExpectDisposedAsync(closing.RentAsync(CancellationToken.None).AsTask());
        checks++;

        // Simulate Processed and shutdown arriving together on worker threads.
        // A double-return or a disposed synchronization primitive breaks this.
        for (int iteration = 0; iteration < 50; iteration++)
        {
            var buffers = new RecordingFrameBuffers(4);
            var frame = await buffers.RentAsync(CancellationToken.None);
            await Task.WhenAll(Task.Run(frame.Dispose), Task.Run(frame.Dispose), Task.Run(buffers.Dispose));
            await ExpectDisposedAsync(buffers.RentAsync(CancellationToken.None).AsTask());
        }
        checks++;

        using (var buffers = new RecordingFrameBuffers(4))
        using (var cancellation = new CancellationTokenSource())
        {
            cancellation.Cancel();
            await ExpectCancellationAsync(buffers.RentAsync(cancellation.Token).AsTask());
            checks++;
        }

        const int frameLength = 3840 * 2160 * 3 / 2;
        const int measuredFrames = 30;
        long before = GC.GetAllocatedBytesForCurrentThread();
        byte[]? baseline = null;
        for (int index = 0; index < measuredFrames; index++) { baseline = new byte[frameLength]; baseline[0] = (byte)index; }
        long baselineBytes = GC.GetAllocatedBytesForCurrentThread() - before;
        GC.KeepAlive(baseline);
        using (var buffers = new RecordingFrameBuffers(frameLength))
        {
            using (var warm = await buffers.RentAsync(CancellationToken.None)) warm.Pixels[0] = 0;
            before = GC.GetAllocatedBytesForCurrentThread();
            for (int index = 0; index < measuredFrames; index++)
            {
                using var frame = buffers.RentAsync(CancellationToken.None).GetAwaiter().GetResult();
                frame.Pixels[0] = (byte)index;
            }
            long reusedBytes = GC.GetAllocatedBytesForCurrentThread() - before;
            Require(baselineBytes >= (long)measuredFrames * frameLength, "allocation baseline includes every full-sized frame array");
            Require(reusedBytes < frameLength, "steady-state capture allocates less than one frame across thirty frames");
            Console.WriteLine($"Recording NV12 sample buffers: 4K × {measuredFrames} frames, per-frame arrays {baselineBytes:N0} B; warmed reuse {reusedBytes:N0} B ({100.0 * (1 - (double)reusedBytes / baselineBytes):F4}% less); at most four {frameLength:N0}-byte submitted arrays plus one BGRA capture scratch per session.");
        }
        return checks;
    }

    private static async Task ExpectCancellationAsync(Task task)
    {
        try { await task.WaitAsync(TimeSpan.FromSeconds(2)); }
        catch (OperationCanceledException) { return; }
        throw new InvalidOperationException("Waiting for a frame ignored cancellation.");
    }

    private static async Task ExpectDisposedAsync(Task task)
    {
        try { await task.WaitAsync(TimeSpan.FromSeconds(2)); }
        catch (ObjectDisposedException) { return; }
        throw new InvalidOperationException("Closed frame storage still rented pixels.");
    }
}
