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
    private VideoSinkWriter(string path, int sourceWidth, int sourceHeight, RecordingQuality quality, VideoExportMetrics? metrics)
    {
        thread = new Thread(() =>
        {
            bool com = false, foundation = false;
            try
            {
                NativeWriter.Check(CoInitializeEx(0, 0)); com = true;
                NativeWriter.Check(MFStartup(0x20070, 0)); foundation = true;
                writer = new NativeWriter(path, sourceWidth, sourceHeight, quality, metrics); ready.TrySetResult();
                foreach (var request in requests.GetConsumingEnumerable()) request();
            }
            catch (Exception error) { ready.TrySetException(error); }
            finally { writer?.Dispose(); if (foundation) MFShutdown(); if (com) CoUninitialize(); }
        }) { IsBackground = true, Name = "Slightshot direct video encoder" };
        thread.SetApartmentState(ApartmentState.MTA); thread.Start();
    }
    internal static async Task<VideoSinkWriter> OpenAsync(string path, int width, int height, RecordingQuality quality, VideoExportMetrics? metrics = null)
    {
        var writer = new VideoSinkWriter(path, width, height, quality, metrics);
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
        private readonly int width, height;
        private readonly byte[] converted;
        private readonly BgraResizer? resizer;
        private readonly byte[]? resized;
        private readonly VideoExportMetrics? metrics;
        private ulong submittedSamples;
        internal NativeWriter(string path, int sourceWidth, int sourceHeight, RecordingQuality quality, VideoExportMetrics? metrics)
        {
            this.metrics = metrics;
            var size = quality.Dimensions(sourceWidth, sourceHeight); int rate = quality.FramesPerSecond();
            width = size.Width; height = size.Height;
            byteCount = checked(width * height * 3 / 2); converted = new byte[byteCount];
            if (sourceWidth != size.Width || sourceHeight != size.Height)
            {
                resizer = new(sourceWidth, sourceHeight, size.Width, size.Height); resized = new byte[checked(width * height * 4)];
            }
            nint attributes = 0, output = 0, input = 0, parameters = 0;
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
                input = VideoType(new("3231564e-0000-0010-8000-00aa00389b71"), size.Width, size.Height, rate); // NV12, accepted directly by H.264
                SetUInt32(input, new("644b4e48-1e02-4516-b0eb-c01ca9d49ac6"), checked((uint)size.Width));
                Check(MFCreateAttributes(out parameters, 1));
                // Supply encoder settings during input negotiation, before
                // BeginWriting. Avoid presentation-time reordering at time zero.
                SetUInt32(parameters, new("8d390aac-dc5c-4200-b57f-814d04babab2"), 0);
                Check(((delegate* unmanaged[Stdcall]<nint, uint, nint, nint, int>)Slot(sink, 4))(sink, stream, input, parameters));
                ConfigureWorkerThreads();
                ConfigureColorProcessors();
                Check(((delegate* unmanaged[Stdcall]<nint, int>)Slot(sink, 5))(sink));
            }
            catch { Dispose(); throw; }
            finally { Release(parameters); Release(input); Release(output); Release(attributes); }
        }
        internal void Write(byte[] source, TimeSpan position, TimeSpan duration, CancellationToken cancellation, VideoExportMetrics? metrics)
        {
            cancellation.ThrowIfCancellationRequested();
            long measured = System.Diagnostics.Stopwatch.GetTimestamp();
            byte[] pixels = source;
            if (resizer != null) { resizer.Resize(source, resized!); pixels = resized!; }
            metrics?.AddResize(System.Diagnostics.Stopwatch.GetElapsedTime(measured).TotalMilliseconds);
            measured = System.Diagnostics.Stopwatch.GetTimestamp();
            BgraToNv12.Convert(pixels, converted, width, height); pixels = converted;
            metrics?.AddColorConversion(System.Diagnostics.Stopwatch.GetElapsedTime(measured).TotalMilliseconds);
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
                submittedSamples++;
                RecordStatistics();
            }
            finally { Release(sample); Release(buffer); }
        }
        internal void Finish(CancellationToken cancellation)
        {
            cancellation.ThrowIfCancellationRequested();
            Check(((delegate* unmanaged[Stdcall]<nint, int>)Slot(sink, 11))(sink));
            ulong? encoded = RecordStatistics();
            if (encoded is ulong count && count != submittedSamples)
                throw new InvalidOperationException($"Windows encoded {count} of {submittedSamples} edited video frames. The original recording and destination have been preserved.");
            cancellation.ThrowIfCancellationRequested();
        }
        private void ConfigureWorkerThreads()
        {
            // The software H.264 encoder selects its own worker count by
            // default. Bound this native parallelism without changing bitrate,
            // quality, GOP structure or the hardware encoder selection.
            Guid service = Guid.Empty, codecInterface = new("901db4c7-31ce-41a2-85dc-8fa0bf41b8da");
            nint codec = 0;
            int found = ((delegate* unmanaged[Stdcall]<nint, uint, Guid*, Guid*, nint*, int>)Slot(sink, 12))(sink, stream, &service, &codecInterface, &codec);
            if (found < 0) return;
            try
            {
                Guid workerThreads = new("b0c8bf60-16f7-4951-a30b-1db1609293d6");
                Guid bPictures = new("8d390aac-dc5c-4200-b57f-814d04babab2");
                bool bSupported = ((delegate* unmanaged[Stdcall]<nint, Guid*, int>)Slot(codec, 3))(codec, &bPictures) == 0;
                Variant bActual = default;
                try
                {
                    if (bSupported && ((delegate* unmanaged[Stdcall]<nint, Guid*, Variant*, int>)Slot(codec, 8))(codec, &bPictures, &bActual) == 0 && bActual.Type == 19)
                        metrics?.RecordBFrames(bActual.UInt32);
                }
                finally { VariantClear(ref bActual); }
                int supported = ((delegate* unmanaged[Stdcall]<nint, Guid*, int>)Slot(codec, 3))(codec, &workerThreads);
                metrics?.RecordWorkerSupport(supported == 0);
                if (supported != 0) return; // S_FALSE means unsupported.
                Variant requested = new() { Type = 19, UInt32 = 1 }; // VT_UI4
                int applied = ((delegate* unmanaged[Stdcall]<nint, Guid*, Variant*, int>)Slot(codec, 9))(codec, &workerThreads, &requested);
                Variant actual = default;
                try
                {
                    if (((delegate* unmanaged[Stdcall]<nint, Guid*, Variant*, int>)Slot(codec, 8))(codec, &workerThreads, &actual) == 0 && actual.Type == 19)
                        metrics?.RecordWorkerThreads(actual.UInt32, applied == 0);
                }
                finally { VariantClear(ref actual); }
            }
            finally { Release(codec); }
        }
        private ulong? RecordStatistics()
        {
            Statistics statistics = new() { Size = (uint)sizeof(Statistics) };
            if (((delegate* unmanaged[Stdcall]<nint, uint, Statistics*, int>)Slot(sink, 13))(sink, stream, &statistics) == 0)
            {
                metrics?.AddWriterStatistics(statistics.BytesQueued, statistics.Received, statistics.Encoded, statistics.Processed);
                return statistics.Encoded;
            }
            return null;
        }
        private void ConfigureColorProcessors()
        {
            Guid extendedInterface = new("588d72ab-5bc1-496a-8714-b70617141b25"); nint extended = 0;
            if (((delegate* unmanaged[Stdcall]<nint, Guid*, nint*, int>)Slot(sink, 0))(sink, &extendedInterface, &extended) != 0) return;
            try
            {
                for (uint index = 0; index < 8; index++)
                {
                    Guid category = default; nint transform = 0, attributes = 0;
                    try
                    {
                        if (((delegate* unmanaged[Stdcall]<nint, uint, uint, Guid*, nint*, int>)Slot(extended, 14))(extended, stream, index, &category, &transform) != 0) break;
                        Guid classId = Guid.Empty; int applied = -1; uint? actual = null;
                        if (((delegate* unmanaged[Stdcall]<nint, nint*, int>)Slot(transform, 8))(transform, &attributes) == 0)
                        {
                            Guid classKey = new("6821c42b-65a4-4e82-99bc-9a88205ecd0c");
                            _ = ((delegate* unmanaged[Stdcall]<nint, Guid*, Guid*, int>)Slot(attributes, 10))(attributes, &classKey, &classId);
                            if (category == new Guid("302ea3fc-aa5f-47f9-9f7a-c2188bb16302") || classId == new Guid("88753b26-5b24-49bd-b2e7-0c445c78c982"))
                            {
                                // We already choose every output timestamp and
                                // partial duration. If the encoder inserts a
                                // processor, prevent it resampling the short tail.
                                Guid disableFrc = new("2c0afa19-7a97-4d5a-9ee8-16d4fc518d8c");
                                applied = ((delegate* unmanaged[Stdcall]<nint, Guid*, uint, int>)Slot(attributes, 21))(attributes, &disableFrc, 1);
                                uint value = 0;
                                if (((delegate* unmanaged[Stdcall]<nint, Guid*, uint*, int>)Slot(attributes, 7))(attributes, &disableFrc, &value) == 0) actual = value;
                            }
                        }
                        metrics?.RecordTransform(new(index, category, classId, applied == 0, actual));
                    }
                    finally { Release(attributes); Release(transform); }
                }
            }
            finally { Release(extended); }
        }
        [StructLayout(LayoutKind.Explicit, Size = 24)]
        private struct Variant { [FieldOffset(0)] public ushort Type; [FieldOffset(8)] public uint UInt32; }
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
                SetUInt32(type, new("3e23d450-2c75-4d25-a00e-b91670d12327"), 1); // BT.709 matrix
                SetUInt32(type, new("c21b8ee5-b956-4071-8daf-325edf5cab11"), 2); // studio/limited range
                SetUInt32(type, new("dbfbe4d7-0740-4ee0-8192-850ab0e21935"), 2); // BT.709 primaries
                SetUInt32(type, new("5fb0fce9-be5c-4935-a811-ec838f8eed93"), 5); // BT.709 transfer
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
        [DllImport("oleaut32.dll")] private static extern int VariantClear(ref Variant variant);
    }
}
