using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using Slightshot.Core;

namespace Slightshot;

// Direct, throttled MF writes replace the MediaStreamSource/MediaTranscoder
// input bridge with a sequential writer. One owned MTA owns creation,
// encoding, finalization and every COM release.
internal sealed class VideoSinkWriter : IDisposable
{
    private readonly BlockingCollection<Action> requests = new(1);
    private readonly TaskCompletionSource ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly Thread thread;
    private NativeWriter? writer;
    private VideoSinkWriter(string path, int sourceWidth, int sourceHeight, RecordingQuality quality)
    {
        thread = new Thread(() =>
        {
            bool com = false, foundation = false;
            try
            {
                NativeWriter.Check(CoInitializeEx(0, 0)); com = true;
                NativeWriter.Check(MFStartup(0x20070, 0)); foundation = true;
                writer = new NativeWriter(path, sourceWidth, sourceHeight, quality); ready.TrySetResult();
                foreach (var request in requests.GetConsumingEnumerable()) request();
            }
            catch (Exception error) { ready.TrySetException(error); }
            finally { writer?.Dispose(); if (foundation) MFShutdown(); if (com) CoUninitialize(); }
        }) { IsBackground = true, Name = "Slightshot direct video encoder" };
        thread.SetApartmentState(ApartmentState.MTA); thread.Start();
    }
    internal static async Task<VideoSinkWriter> OpenAsync(string path, int width, int height, RecordingQuality quality)
    {
        var writer = new VideoSinkWriter(path, width, height, quality);
        try { await writer.ready.Task.ConfigureAwait(false); return writer; }
        catch { writer.Dispose(); throw; }
    }
    internal Task WriteAsync(byte[] pixels, TimeSpan position, TimeSpan duration, CancellationToken cancellation, VideoExportMetrics? metrics)
        => Dispatch(() => writer!.Write(pixels, position, duration, cancellation, metrics), cancellation);
    internal Task FinishAsync(CancellationToken cancellation) => Dispatch(() => writer!.Finish(cancellation), cancellation);
    private Task Dispatch(Action action, CancellationToken cancellation)
    {
        cancellation.ThrowIfCancellationRequested();
        var completed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        requests.Add(() =>
        {
            try { cancellation.ThrowIfCancellationRequested(); action(); completed.TrySetResult(); }
            catch (OperationCanceledException) { completed.TrySetCanceled(cancellation); }
            catch (Exception error) { completed.TrySetException(error); }
        }, cancellation);
        return completed.Task;
    }
    public void Dispose() { requests.CompleteAdding(); thread.Join(); requests.Dispose(); }
    [DllImport("ole32.dll")] private static extern int CoInitializeEx(nint reserved, uint flags);
    [DllImport("ole32.dll")] private static extern void CoUninitialize();
    [DllImport("mfplat.dll")] private static extern int MFStartup(uint version, uint flags);
    [DllImport("mfplat.dll")] private static extern int MFShutdown();

    private sealed unsafe class NativeWriter : IDisposable
    {
        private nint sink;
        private uint stream;
        private readonly int byteCount;
        private readonly BgraResizer? resizer;
        private readonly byte[]? resized;
        internal NativeWriter(string path, int sourceWidth, int sourceHeight, RecordingQuality quality)
        {
            var size = quality.Dimensions(sourceWidth, sourceHeight); int rate = quality.FramesPerSecond();
            byteCount = checked(size.Width * size.Height * 4);
            if (sourceWidth != size.Width || sourceHeight != size.Height)
            {
                resizer = new(sourceWidth, sourceHeight, size.Width, size.Height); resized = new byte[byteCount];
            }
            nint attributes = 0, output = 0, input = 0;
            try
            {
                Check(MFCreateAttributes(out attributes, 1));
                SetUInt32(attributes, new("a634a91c-822b-41b9-a494-4de4643612b0"), 1); // hardware encoder when available
                // Leave MF_SINK_WRITER_DISABLE_THROTTLING absent: WriteSample
                // supplies native backpressure before the next frame is reused.
                Check(MFCreateSinkWriterFromURL(path, 0, attributes, out sink));
                output = VideoType(new("34363248-0000-0010-8000-00aa00389b71"), size.Width, size.Height, rate); // H.264
                SetUInt32(output, new("20332624-fb0d-4d9e-bd0d-cbf6786c102e"), quality.Bitrate(size.Width, size.Height));
                var profile = RecordingExport.Profile(quality, sourceWidth, sourceHeight);
                uint profileId = profile.Video.Properties.TryGetValue(new("ad76a80b-2d5c-4e0b-b375-64e520137036"), out var profileValue) ? Convert.ToUInt32(profileValue) : 100;
                SetUInt32(output, new("ad76a80b-2d5c-4e0b-b375-64e520137036"), profileId);
                uint selected = 0; Check(((delegate* unmanaged[Stdcall]<nint, nint, uint*, int>)Slot(sink, 3))(sink, output, &selected)); stream = selected;
                input = VideoType(new("00000016-0000-0010-8000-00aa00389b71"), size.Width, size.Height, rate); // RGB32
                SetUInt32(input, new("644b4e48-1e02-4516-b0eb-c01ca9d49ac6"), checked((uint)(size.Width * 4)));
                Check(((delegate* unmanaged[Stdcall]<nint, uint, nint, nint, int>)Slot(sink, 4))(sink, stream, input, 0));
                Check(((delegate* unmanaged[Stdcall]<nint, int>)Slot(sink, 5))(sink));
            }
            catch { Dispose(); throw; }
            finally { Release(input); Release(output); Release(attributes); }
        }
        internal void Write(byte[] source, TimeSpan position, TimeSpan duration, CancellationToken cancellation, VideoExportMetrics? metrics)
        {
            cancellation.ThrowIfCancellationRequested();
            long measured = System.Diagnostics.Stopwatch.GetTimestamp();
            byte[] pixels = source;
            if (resizer != null) { resizer.Resize(source, resized!); pixels = resized!; }
            metrics?.AddResize(System.Diagnostics.Stopwatch.GetElapsedTime(measured).TotalMilliseconds);
            nint sample = 0, buffer = 0, data = 0;
            try
            {
                Check(MFCreateMemoryBuffer(checked((uint)byteCount), out buffer));
                uint maximum = 0, length = 0;
                Check(((delegate* unmanaged[Stdcall]<nint, nint*, uint*, uint*, int>)Slot(buffer, 3))(buffer, &data, &maximum, &length));
                try { if (maximum < byteCount) throw new InvalidOperationException("Windows allocated an undersized video encoder buffer."); Marshal.Copy(pixels, 0, data, byteCount); }
                finally { Check(((delegate* unmanaged[Stdcall]<nint, int>)Slot(buffer, 4))(buffer)); }
                Check(((delegate* unmanaged[Stdcall]<nint, uint, int>)Slot(buffer, 6))(buffer, checked((uint)byteCount)));
                Check(MFCreateSample(out sample));
                Check(((delegate* unmanaged[Stdcall]<nint, nint, int>)Slot(sample, 42))(sample, buffer));
                Check(((delegate* unmanaged[Stdcall]<nint, long, int>)Slot(sample, 36))(sample, position.Ticks));
                Check(((delegate* unmanaged[Stdcall]<nint, long, int>)Slot(sample, 38))(sample, duration.Ticks));
                cancellation.ThrowIfCancellationRequested();
                Check(((delegate* unmanaged[Stdcall]<nint, uint, nint, int>)Slot(sink, 6))(sink, stream, sample));
                Statistics statistics = new() { Size = (uint)sizeof(Statistics) };
                if (((delegate* unmanaged[Stdcall]<nint, uint, Statistics*, int>)Slot(sink, 13))(sink, stream, &statistics) >= 0) metrics?.AddWriterQueue(statistics.BytesQueued);
            }
            finally { Release(sample); Release(buffer); }
        }
        internal void Finish(CancellationToken cancellation)
        {
            cancellation.ThrowIfCancellationRequested();
            Check(((delegate* unmanaged[Stdcall]<nint, int>)Slot(sink, 11))(sink));
            cancellation.ThrowIfCancellationRequested();
        }
        private static nint VideoType(Guid subtype, int width, int height, int rate)
        {
            Check(MFCreateMediaType(out nint type));
            try
            {
                SetGuid(type, new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f"), new("73646976-0000-0010-8000-00aa00389b71"));
                SetGuid(type, new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5"), subtype);
                SetUInt32(type, new("e2724bb8-e676-4806-b4b2-a8d6efb44ccd"), 2); // progressive
                SetUInt64(type, new("1652c33d-d6b2-4012-b834-72030849a37d"), ((ulong)(uint)width << 32) | (uint)height);
                SetUInt64(type, new("c459a2e8-3d2c-4e44-b132-fee5156c7bb0"), ((ulong)(uint)rate << 32) | 1);
                SetUInt64(type, new("c6376a1e-8d0a-4027-be45-6d9a0ad39bb6"), (1UL << 32) | 1);
                return type;
            }
            catch { Release(type); throw; }
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct Statistics
        {
            public uint Size; public long LastReceived, LastEncoded, LastProcessed, LastTick, LastRequest;
            public ulong Received, Encoded, Processed, Ticks; public uint BytesQueued; public ulong BytesProcessed;
            public uint Outstanding, RateReceived, RateEncoded, RateProcessed;
        }
        private static nint Slot(nint instance, int index) => Marshal.ReadIntPtr(Marshal.ReadIntPtr(instance), index * IntPtr.Size);
        private static void SetUInt32(nint attributes, Guid key, uint value) => Check(((delegate* unmanaged[Stdcall]<nint, Guid*, uint, int>)Slot(attributes, 21))(attributes, &key, value));
        private static void SetUInt64(nint attributes, Guid key, ulong value) => Check(((delegate* unmanaged[Stdcall]<nint, Guid*, ulong, int>)Slot(attributes, 22))(attributes, &key, value));
        private static void SetGuid(nint attributes, Guid key, Guid value) => Check(((delegate* unmanaged[Stdcall]<nint, Guid*, Guid*, int>)Slot(attributes, 24))(attributes, &key, &value));
        internal static void Check(int result) => Marshal.ThrowExceptionForHR(result);
        private static void Release(nint instance) { if (instance != 0) Marshal.Release(instance); }
        public void Dispose() { Release(sink); sink = 0; }
        [DllImport("mfplat.dll")] private static extern int MFCreateAttributes(out nint attributes, uint size);
        [DllImport("mfplat.dll")] private static extern int MFCreateMediaType(out nint mediaType);
        [DllImport("mfplat.dll")] private static extern int MFCreateMemoryBuffer(uint size, out nint buffer);
        [DllImport("mfplat.dll")] private static extern int MFCreateSample(out nint sample);
        [DllImport("mfreadwrite.dll", CharSet = CharSet.Unicode)] private static extern int MFCreateSinkWriterFromURL(string path, nint byteStream, nint attributes, out nint writer);
    }
}
