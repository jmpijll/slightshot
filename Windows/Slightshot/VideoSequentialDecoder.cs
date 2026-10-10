using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using Slightshot.Core;

namespace Slightshot;

// A sequential Media Foundation reader avoids seek + thumbnail image encoding
// for every exported frame. All COM work and release stay on one owned MTA.
internal sealed class VideoSequentialDecoder : IDisposable
{
    private readonly BlockingCollection<Action> requests = new(1);
    private readonly TaskCompletionSource ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly Thread thread;
    private NativeReader? reader;
    private VideoSequentialDecoder(string path, int width, int height, bool metadataOnly = false, VideoExportMetrics? metrics = null)
    {
        thread = new Thread(() =>
        {
            bool com = false, foundation = false;
            try
            {
                NativeReader.Check(CoInitializeEx(0, 0)); com = true;
                NativeReader.Check(MFStartup(0x20070, 0)); foundation = true;
                reader = new NativeReader(path, width, height, metadataOnly, metrics); ready.TrySetResult();
                foreach (var request in requests.GetConsumingEnumerable()) request();
            }
            catch (Exception error) { ready.TrySetException(error); }
            finally { reader?.Dispose(); if (foundation) MFShutdown(); if (com) CoUninitialize(); }
        }) { IsBackground = true, Name = "Slightshot sequential video decoder" };
        thread.SetApartmentState(ApartmentState.MTA); thread.Start();
    }
    internal static async Task<VideoSequentialDecoder> OpenAsync(string path, int width, int height, VideoExportMetrics? metrics = null)
    {
        var decoder = new VideoSequentialDecoder(path, width, height, metrics: metrics);
        try { await decoder.ready.Task.ConfigureAwait(false); return decoder; }
        catch { decoder.Dispose(); throw; }
    }
    internal Task GetFrameAsync(TimeSpan position, byte[] output, CancellationToken cancellation)
    {
        cancellation.ThrowIfCancellationRequested();
        var completed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        requests.Add(() =>
        {
            try { reader!.CopyFrame(position, output, cancellation); completed.TrySetResult(); }
            catch (OperationCanceledException) { completed.TrySetCanceled(cancellation); }
            catch (Exception error) { completed.TrySetException(error); }
        }, cancellation);
        return completed.Task;
    }
    internal static async Task<VideoDecodedStatistics> InspectAsync(string path, int width, int height, CancellationToken cancellation = default)
    {
        using var decoder = new VideoSequentialDecoder(path, width, height, metadataOnly: true);
        await decoder.ready.Task.ConfigureAwait(false);
        var completed = new TaskCompletionSource<VideoDecodedStatistics>(TaskCreationOptions.RunContinuationsAsynchronously);
        decoder.requests.Add(() =>
        {
            try { completed.TrySetResult(decoder.reader!.Inspect(cancellation)); }
            catch (OperationCanceledException) { completed.TrySetCanceled(cancellation); }
            catch (Exception error) { completed.TrySetException(error); }
        }, cancellation);
        return await completed.Task.ConfigureAwait(false);
    }
    public void Dispose() { requests.CompleteAdding(); thread.Join(); requests.Dispose(); }

    [DllImport("ole32.dll")] private static extern int CoInitializeEx(nint reserved, uint flags);
    [DllImport("ole32.dll")] private static extern void CoUninitialize();
    [DllImport("mfplat.dll")] private static extern int MFStartup(uint version, uint flags);
    [DllImport("mfplat.dll")] private static extern int MFShutdown();

    // These typed ABI slots are the published IMFAttributes, IMFSourceReader,
    // IMFSample and IMFMediaBuffer vtables in the Microsoft Windows SDK headers.
    // They keep the interop limited to the handful of methods actually used.
    private sealed unsafe class NativeReader : IDisposable
    {
        private const uint FirstVideo = 0xfffffffc;
        private nint source;
        private readonly int width, height;
        private int defaultStride, decodedWidth, decodedHeight, cropX, cropY;
        private Nv12Matrix matrix;
        private bool fullRange;
        private readonly VideoExportMetrics? metrics;
        private byte[] current = [], next = [];
        private ExactSizeBufferPool.BufferLease? currentLease, nextLease;
        private long nextTime, sourceOrigin;
        private bool hasCurrent, hasNext, ended;
        internal NativeReader(string path, int width, int height, bool metadataOnly, VideoExportMetrics? metrics)
        {
            this.width = width; this.height = height; this.metrics = metrics;
            nint attributes = 0, mediaType = 0;
            try
            {
                if (!metadataOnly)
                {
                    int byteCount = checked(width * height * 4);
                    currentLease = VideoPixelBuffers.Shared.Rent(byteCount); current = currentLease.Pixels;
                    nextLease = VideoPixelBuffers.Shared.Rent(byteCount); next = nextLease.Pixels;
                }
                // Decode native NV12 without inserting a full-resolution RGB
                // processor. Convert directly into the bounded BGRA leases.
                Check(MFCreateAttributes(out attributes, 1));
                Check(MFCreateSourceReaderFromURL(path, attributes, out source));
                Check(((delegate* unmanaged[Stdcall]<nint, uint, int, int>)Slot(source, 4))(source, 0xfffffffe, 0)); // deselect all
                Check(((delegate* unmanaged[Stdcall]<nint, uint, int, int>)Slot(source, 4))(source, FirstVideo, 1));
                Check(MFCreateMediaType(out mediaType));
                SetGuid(mediaType, new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f"), new("73646976-0000-0010-8000-00aa00389b71"));
                SetGuid(mediaType, new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5"), new("3231564e-0000-0010-8000-00aa00389b71"));
                Check(((delegate* unmanaged[Stdcall]<nint, uint, nint, nint, int>)Slot(source, 7))(source, FirstVideo, 0, mediaType));
                if (!metadataOnly) { ConfigureWorkerThreads(metrics); ValidateFormat(); }
            }
            catch { Dispose(); throw; }
            finally { Release(mediaType); Release(attributes); }
        }
        private void ConfigureWorkerThreads(VideoExportMetrics? metrics)
        {
            // H.264 documents this decoder attribute before streaming. Limit
            // native parallelism separately from the encoder's worker setting.
            Guid extendedInterface = new("7b981cf0-560e-4116-9875-b099895f23d7"), category = default, classId = default;
            nint extended = 0, transform = 0, attributes = 0;
            bool available = false, applied = false; uint? configured = null; int? previous = null;
            try
            {
                if (((delegate* unmanaged[Stdcall]<nint, Guid*, nint*, int>)Slot(source, 0))(source, &extendedInterface, &extended) != 0) return;
                if (((delegate* unmanaged[Stdcall]<nint, uint, uint, Guid*, nint*, int>)Slot(extended, 16))(extended, FirstVideo, 0, &category, &transform) != 0
                    || category != new Guid("d6c02d4b-6833-45b4-971a-05a4b04bab91")) return;
                if (((delegate* unmanaged[Stdcall]<nint, nint*, int>)Slot(transform, 8))(transform, &attributes) != 0) return;
                available = true;
                Guid classKey = new("6821c42b-65a4-4e82-99bc-9a88205ecd0c"), workers = new("9561c3e8-ea9e-4435-9b1e-a93e691894d8");
                _ = ((delegate* unmanaged[Stdcall]<nint, Guid*, Guid*, int>)Slot(attributes, 10))(attributes, &classKey, &classId);
                uint value = 0;
                if (((delegate* unmanaged[Stdcall]<nint, Guid*, uint*, int>)Slot(attributes, 7))(attributes, &workers, &value) == 0) previous = unchecked((int)value);
                applied = ((delegate* unmanaged[Stdcall]<nint, Guid*, uint, int>)Slot(attributes, 21))(attributes, &workers, 1) == 0;
                if (((delegate* unmanaged[Stdcall]<nint, Guid*, uint*, int>)Slot(attributes, 7))(attributes, &workers, &value) == 0) configured = value;
            }
            finally
            {
                metrics?.RecordDecoderWorkerControl(available, applied, configured, previous, category, classId);
                Release(attributes); Release(transform); Release(extended);
            }
        }
        private void ValidateFormat()
        {
            nint negotiated = 0;
            try
            {
                Check(((delegate* unmanaged[Stdcall]<nint, uint, nint*, int>)Slot(source, 6))(source, FirstVideo, &negotiated));
                Guid sizeKey = new("1652c33d-d6b2-4012-b834-72030849a37d"); ulong dimensions = 0;
                Check(((delegate* unmanaged[Stdcall]<nint, Guid*, ulong*, int>)Slot(negotiated, 8))(negotiated, &sizeKey, &dimensions));
                decodedWidth = checked((int)(dimensions >> 32)); decodedHeight = checked((int)(dimensions & uint.MaxValue));
                cropX = cropY = 0;
                if (decodedWidth != width || decodedHeight != height)
                {
                    // H.264 decoders may expose macroblock padding (360→368)
                    // after their first sample. The visible display aperture
                    // must match the source exactly; only that region is copied.
                    bool cropped = TryAperture(negotiated, new("d7388766-18fe-48c6-a177-ee894867c8c4"))
                        || TryAperture(negotiated, new("66758743-7e5f-400d-980a-aa8596c85696"));
                    if (!cropped) throw new InvalidOperationException($"Windows changed the decoded video to {decodedWidth}×{decodedHeight}; no exact {width}×{height} display aperture was present.");
                }
                Guid subtypeKey = new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5"), subtype = default;
                Check(((delegate* unmanaged[Stdcall]<nint, Guid*, Guid*, int>)Slot(negotiated, 10))(negotiated, &subtypeKey, &subtype));
                if (subtype != new Guid("3231564e-0000-0010-8000-00aa00389b71")) throw new InvalidOperationException("Windows changed the decoded video pixel format from 8-bit NV12.");
                if (width <= 0 || height <= 0 || decodedWidth <= 0 || decodedHeight <= 0
                    || ((width | height | decodedWidth | decodedHeight | cropX | cropY) & 1) != 0)
                    throw new InvalidOperationException("The decoded NV12 dimensions and display aperture must align to complete 2×2 chroma blocks.");
                Guid strideKey = new("644b4e48-1e02-4516-b0eb-c01ca9d49ac6"); uint stride = 0;
                int strideResult = ((delegate* unmanaged[Stdcall]<nint, Guid*, uint*, int>)Slot(negotiated, 7))(negotiated, &strideKey, &stride);
                defaultStride = strideResult >= 0 ? unchecked((int)stride) : decodedWidth;
                if (defaultStride < decodedWidth) throw new InvalidOperationException("Windows returned an invalid top-down NV12 stride.");
                ValidateColor(negotiated);
                Guid rotationKey = new("c380465d-2271-428c-9b83-ecea3b4a85c1"); uint rotation = 0;
                int rotated = ((delegate* unmanaged[Stdcall]<nint, Guid*, uint*, int>)Slot(negotiated, 7))(negotiated, &rotationKey, &rotation);
                // Slightshot's own recordings have no orientation metadata.
                // Refuse an unexpected rotated file rather than silently
                // export pixels that disagree with the upright native preview.
                if (rotated >= 0 && rotation != 0) throw new InvalidOperationException("This recording has unsupported rotation metadata.");
            }
            finally { Release(negotiated); }
        }
        private void ValidateColor(nint mediaType)
        {
            static uint? Value(nint attributes, Guid key)
            {
                uint value = 0;
                return ((delegate* unmanaged[Stdcall]<nint, Guid*, uint*, int>)Slot(attributes, 7))(attributes, &key, &value) == 0 ? value : null;
            }
            uint? rawMatrix = Value(mediaType, new("3e23d450-2c75-4d25-a00e-b91670d12327"));
            uint? range = Value(mediaType, new("c21b8ee5-b956-4071-8daf-325edf5cab11"));
            uint? primaries = Value(mediaType, new("dbfbe4d7-0740-4ee0-8192-850ab0e21935"));
            uint? transfer = Value(mediaType, new("5fb0fce9-be5c-4935-a811-ec838f8eed93"));
            // MF documents unknown matrix as BT.709. Our own SDR H.264
            // recordings use limited range when no full-range flag is present;
            // record this default explicitly instead of guessing by resolution.
            var color = Nv12ColorProfile.ForSdrH264(rawMatrix, range, primaries, transfer);
            matrix = color.Matrix; fullRange = color.FullRange;
            metrics?.RecordDecoderColor(new(rawMatrix, range, primaries, transfer, matrix.ToString(), fullRange,
                rawMatrix is null or 0 ? "MF unknown matrix defaults to BT.709" : "Negotiated MF matrix",
                range is null or 0 ? "Own SDR H.264 recording: absent full-range flag defaults to limited range" : "Negotiated MF nominal range"));
        }
        private bool TryAperture(nint mediaType, Guid key)
        {
            VideoArea area = default; uint size = 0;
            int result = ((delegate* unmanaged[Stdcall]<nint, Guid*, VideoArea*, uint, uint*, int>)Slot(mediaType, 15))(mediaType, &key, &area, (uint)sizeof(VideoArea), &size);
            if (result < 0 || size != sizeof(VideoArea) || area.Width != width || area.Height != height || area.XFraction != 0 || area.YFraction != 0
                || area.X < 0 || area.Y < 0 || area.X + (long)width > decodedWidth || area.Y + (long)height > decodedHeight) return false;
            cropX = area.X; cropY = area.Y; return true;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct VideoArea { public ushort XFraction; public short X; public ushort YFraction; public short Y; public int Width; public int Height; }
        internal VideoDecodedStatistics Inspect(CancellationToken cancellation)
        {
            var timestamps = new List<long>(); long finalDuration = 0;
            for (;;)
            {
                cancellation.ThrowIfCancellationRequested();
                nint sample = 0; uint stream = 0, flags = 0; long time = 0;
                try
                {
                    Check(((delegate* unmanaged[Stdcall]<nint, uint, uint, uint*, uint*, long*, nint*, int>)Slot(source, 9))
                        (source, FirstVideo, 0, &stream, &flags, &time, &sample));
                    if ((flags & 1) != 0) throw new InvalidOperationException("Windows reported a video inspection decoding error.");
                    if (sample != 0)
                    {
                        timestamps.Add(time); finalDuration = 0; long sampleDuration = 0;
                        if (((delegate* unmanaged[Stdcall]<nint, long*, int>)Slot(sample, 37))(sample, &sampleDuration) >= 0) finalDuration = sampleDuration;
                    }
                    if ((flags & 2) != 0) break;
                }
                finally { Release(sample); }
            }
            return new(timestamps.Count, timestamps.Count == 0 ? 0 : timestamps[0], timestamps.Count == 0 ? 0 : timestamps[^1], finalDuration, timestamps);
        }
        internal void CopyFrame(TimeSpan position, byte[] output, CancellationToken cancellation)
        {
            cancellation.ThrowIfCancellationRequested();
            if (!hasCurrent)
            {
                hasCurrent = Read(current, out sourceOrigin, cancellation);
                if (!hasCurrent) throw new InvalidOperationException("No video samples could be decoded.");
                metrics?.RecordDecoderSourceOrigin(sourceOrigin);
            }
            if (!hasNext && !ended) hasNext = ReadAhead(cancellation);
            // Subtracting two rational frame timestamps can differ from the
            // zero-based output grid by one 100 ns tick after quantization.
            while (hasNext && (nextTime <= position.Ticks || nextTime == position.Ticks + 1))
            {
                (current, next) = (next, current); hasNext = ReadAhead(cancellation);
            }
            Buffer.BlockCopy(current, 0, output, 0, current.Length);
        }
        private bool ReadAhead(CancellationToken cancellation)
        {
            bool decoded = Read(next, out long rawTime, cancellation);
            // Recorder encoders can start their presentation timestamps above
            // zero. Editor/output time zero still denotes the first source frame.
            // Inspect deliberately reports raw timestamps for media validation.
            nextTime = checked(rawTime - sourceOrigin); return decoded;
        }
        private bool Read(byte[] target, out long timestamp, CancellationToken cancellation)
        {
            timestamp = 0;
            while (!ended)
            {
                cancellation.ThrowIfCancellationRequested();
                nint sample = 0, buffer = 0, twoD = 0; uint stream = 0, flags = 0; long time = 0;
                try
                {
                    Check(((delegate* unmanaged[Stdcall]<nint, uint, uint, uint*, uint*, long*, nint*, int>)Slot(source, 9))
                        (source, FirstVideo, 0, &stream, &flags, &time, &sample));
                    if ((flags & 1) != 0) throw new InvalidOperationException("Windows reported a sequential video decoding error.");
                    if ((flags & 0x30) != 0) ValidateFormat();
                    ended = (flags & 2) != 0;
                    if (sample == 0) continue;
                    Check(((delegate* unmanaged[Stdcall]<nint, nint*, int>)Slot(sample, 41))(sample, &buffer));
                    Guid iid = new("33ae5ea6-4316-436f-8ddd-d73d22f829ec");
                    int queried = ((delegate* unmanaged[Stdcall]<nint, Guid*, nint*, int>)Slot(buffer, 0))(buffer, &iid, &twoD);
                    nint pixels = 0; int stride = defaultStride;
                    if (queried >= 0)
                    {
                        nint start = 0; uint length = 0;
                        Check(((delegate* unmanaged[Stdcall]<nint, uint, nint*, int*, nint*, uint*, int>)Slot(twoD, 10))(twoD, 1, &pixels, &stride, &start, &length));
                        try
                        {
                            ConvertPlanes(pixels, stride, start, length, target);
                        }
                        finally { Check(((delegate* unmanaged[Stdcall]<nint, int>)Slot(twoD, 4))(twoD)); }
                    }
                    else
                    {
                        uint maximum = 0, length = 0;
                        Check(((delegate* unmanaged[Stdcall]<nint, nint*, uint*, uint*, int>)Slot(buffer, 3))(buffer, &pixels, &maximum, &length));
                        try
                        {
                            if (checked(defaultStride * (long)decodedHeight * 3 / 2) > length) throw new InvalidOperationException("Decoded NV12 buffer was shorter than its coded dimensions.");
                            ConvertPlanes(pixels, defaultStride, pixels, length, target);
                        }
                        finally { Check(((delegate* unmanaged[Stdcall]<nint, int>)Slot(buffer, 4))(buffer)); }
                    }
                    timestamp = time; return true;
                }
                finally { Release(twoD); Release(buffer); Release(sample); }
            }
            return false;
        }
        private void ConvertPlanes(nint pixels, int stride, nint start, uint length, byte[] target)
        {
            if (stride < decodedWidth) throw new InvalidOperationException("Invalid top-down NV12 scanline pitch.");
            nint luma = pixels + checked((nint)(cropY * (long)stride + cropX));
            // Chroma follows the entire coded Y plane, including macroblock
            // padding such as 640×368, before applying the visible crop.
            nint chroma = pixels + checked((nint)(decodedHeight * (long)stride + cropY / 2L * stride + cropX));
            int lumaLength = checked((height - 1) * stride + width), chromaLength = checked((height / 2 - 1) * stride + width);
            long end = checked((long)start + length);
            if ((long)luma < (long)start || checked((long)luma + lumaLength) > end
                || (long)chroma < (long)start || checked((long)chroma + chromaLength) > end)
                throw new InvalidOperationException("Decoded NV12 planes lie outside their native buffer.");
            Nv12ToBgra.Convert(new ReadOnlySpan<byte>((void*)luma, lumaLength), new ReadOnlySpan<byte>((void*)chroma, chromaLength),
                target, width, height, stride, matrix, fullRange);
        }
        private static nint Slot(nint instance, int index) => Marshal.ReadIntPtr(Marshal.ReadIntPtr(instance), index * IntPtr.Size);
        private static void SetGuid(nint attributes, Guid key, Guid value) => Check(((delegate* unmanaged[Stdcall]<nint, Guid*, Guid*, int>)Slot(attributes, 24))(attributes, &key, &value));
        internal static void Check(int result) => Marshal.ThrowExceptionForHR(result);
        private static void Release(nint instance) { if (instance != 0) Marshal.Release(instance); }
        public void Dispose()
        {
            Release(source); source = 0;
            // Called on the owned MTA after all queued requests finish. Neither
            // decoder nor native buffer can still access returned pixel storage.
            currentLease?.Dispose(); currentLease = null;
            nextLease?.Dispose(); nextLease = null; current = next = [];
        }
        [DllImport("mfplat.dll")] private static extern int MFCreateAttributes(out nint attributes, uint size);
        [DllImport("mfplat.dll")] private static extern int MFCreateMediaType(out nint mediaType);
        [DllImport("mfreadwrite.dll", CharSet = CharSet.Unicode)] private static extern int MFCreateSourceReaderFromURL(string path, nint attributes, out nint sourceReader);
    }
}
internal sealed record VideoDecodedStatistics(int Frames, long FirstPresentationTicks, long LastPresentationTicks,
    long LastDurationTicks, IReadOnlyList<long> PresentationTicks);
