using System.Collections.Concurrent;
using System.Runtime.InteropServices;

namespace Slightshot;

// A sequential Media Foundation reader avoids seek + thumbnail image encoding
// for every exported frame. All COM work and release stay on one owned MTA.
internal sealed class VideoSequentialDecoder : IDisposable
{
    private readonly BlockingCollection<Action> requests = new(1);
    private readonly TaskCompletionSource ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly Thread thread;
    private NativeReader? reader;
    private VideoSequentialDecoder(string path, int width, int height)
    {
        thread = new Thread(() =>
        {
            bool com = false, foundation = false;
            try
            {
                NativeReader.Check(CoInitializeEx(0, 0)); com = true;
                NativeReader.Check(MFStartup(0x20070, 0)); foundation = true;
                reader = new NativeReader(path, width, height); ready.TrySetResult();
                foreach (var request in requests.GetConsumingEnumerable()) request();
            }
            catch (Exception error) { ready.TrySetException(error); }
            finally { reader?.Dispose(); if (foundation) MFShutdown(); if (com) CoUninitialize(); }
        }) { IsBackground = true, Name = "Slightshot sequential video decoder" };
        thread.SetApartmentState(ApartmentState.MTA); thread.Start();
    }
    internal static async Task<VideoSequentialDecoder> OpenAsync(string path, int width, int height)
    {
        var decoder = new VideoSequentialDecoder(path, width, height);
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
        private byte[] current, next;
        private long nextTime;
        private bool hasCurrent, hasNext, ended;
        internal NativeReader(string path, int width, int height)
        {
            this.width = width; this.height = height;
            current = new byte[checked(width * height * 4)]; next = new byte[current.Length];
            nint attributes = 0, mediaType = 0;
            try
            {
                Check(MFCreateAttributes(out attributes, 1));
                // Only progressive YUV→RGB32 conversion is needed. The
                // advanced XVP graph also supports resize/frame-rate changes
                // and reserves a large native 4K surface pool on Windows.
                SetUInt32(attributes, new("fb394f3d-ccf1-42ee-bbb3-f9b845d5681d"), 1); // software RGB32 video processing
                Check(MFCreateSourceReaderFromURL(path, attributes, out source));
                Check(((delegate* unmanaged[Stdcall]<nint, uint, int, int>)Slot(source, 4))(source, 0xfffffffe, 0)); // deselect all
                Check(((delegate* unmanaged[Stdcall]<nint, uint, int, int>)Slot(source, 4))(source, FirstVideo, 1));
                Check(MFCreateMediaType(out mediaType));
                SetGuid(mediaType, new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f"), new("73646976-0000-0010-8000-00aa00389b71"));
                SetGuid(mediaType, new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5"), new("00000016-0000-0010-8000-00aa00389b71")); // RGB32
                Check(((delegate* unmanaged[Stdcall]<nint, uint, nint, nint, int>)Slot(source, 7))(source, FirstVideo, 0, mediaType));
                ValidateFormat();
            }
            catch { Dispose(); throw; }
            finally { Release(mediaType); Release(attributes); }
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
                if (subtype != new Guid("00000016-0000-0010-8000-00aa00389b71")) throw new InvalidOperationException("Windows changed the decoded video pixel format.");
                Guid strideKey = new("644b4e48-1e02-4516-b0eb-c01ca9d49ac6"); uint stride = 0;
                int strideResult = ((delegate* unmanaged[Stdcall]<nint, Guid*, uint*, int>)Slot(negotiated, 7))(negotiated, &strideKey, &stride);
                defaultStride = strideResult >= 0 ? unchecked((int)stride) : checked(-decodedWidth * 4);
                if (Math.Abs((long)defaultStride) < decodedWidth * 4L) throw new InvalidOperationException("Windows returned an invalid decoded video stride.");
                Guid rotationKey = new("c380465d-2271-428c-9b83-ecea3b4a85c1"); uint rotation = 0;
                int rotated = ((delegate* unmanaged[Stdcall]<nint, Guid*, uint*, int>)Slot(negotiated, 7))(negotiated, &rotationKey, &rotation);
                // Slightshot's own recordings have no orientation metadata.
                // Refuse an unexpected rotated file rather than silently
                // export pixels that disagree with the upright native preview.
                if (rotated >= 0 && rotation != 0) throw new InvalidOperationException("This recording has unsupported rotation metadata.");
            }
            finally { Release(negotiated); }
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
        internal void CopyFrame(TimeSpan position, byte[] output, CancellationToken cancellation)
        {
            cancellation.ThrowIfCancellationRequested();
            if (!hasCurrent) { hasCurrent = Read(current, out _, cancellation); if (!hasCurrent) throw new InvalidOperationException("No video samples could be decoded."); }
            if (!hasNext && !ended) hasNext = Read(next, out nextTime, cancellation);
            while (hasNext && nextTime <= position.Ticks)
            {
                (current, next) = (next, current); hasNext = Read(next, out nextTime, cancellation);
            }
            Buffer.BlockCopy(current, 0, output, 0, current.Length);
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
                            nint visible = pixels + checked((nint)(cropY * (long)stride + cropX * 4L));
                            long first = (long)visible, last = checked(first + (height - 1L) * stride);
                            long low = Math.Min(first, last), high = checked(Math.Max(first, last) + width * 4L);
                            if (low < (long)start || high > checked((long)start + length)) throw new InvalidOperationException("Decoded video scanlines lie outside their native buffer.");
                            CopyRows(visible, stride, target);
                        }
                        finally { Check(((delegate* unmanaged[Stdcall]<nint, int>)Slot(twoD, 4))(twoD)); }
                    }
                    else
                    {
                        uint maximum = 0, length = 0;
                        Check(((delegate* unmanaged[Stdcall]<nint, nint*, uint*, uint*, int>)Slot(buffer, 3))(buffer, &pixels, &maximum, &length));
                        try
                        {
                            if (Math.Abs((long)defaultStride) * decodedHeight > length) throw new InvalidOperationException("Decoded video buffer was shorter than its dimensions.");
                            nint first = defaultStride < 0 ? pixels + checked((nint)((decodedHeight - 1L) * -(long)defaultStride)) : pixels;
                            first += checked((nint)(cropY * (long)defaultStride + cropX * 4L));
                            CopyRows(first, defaultStride, target);
                        }
                        finally { Check(((delegate* unmanaged[Stdcall]<nint, int>)Slot(buffer, 4))(buffer)); }
                    }
                    // RGB32's fourth byte is unused; our compositor/transcoder
                    // uses opaque premultiplied BGRA throughout.
                    for (int alpha = 3; alpha < target.Length; alpha += 4) target[alpha] = 255;
                    timestamp = time; return true;
                }
                finally { Release(twoD); Release(buffer); Release(sample); }
            }
            return false;
        }
        private void CopyRows(nint pixels, int stride, byte[] target)
        {
            if (Math.Abs((long)stride) < decodedWidth * 4L) throw new InvalidOperationException("Invalid decoded scanline pitch.");
            for (int row = 0; row < height; row++) Marshal.Copy(pixels + checked((nint)(row * (long)stride)), target, row * width * 4, width * 4);
        }
        private static nint Slot(nint instance, int index) => Marshal.ReadIntPtr(Marshal.ReadIntPtr(instance), index * IntPtr.Size);
        private static void SetUInt32(nint attributes, Guid key, uint value) => Check(((delegate* unmanaged[Stdcall]<nint, Guid*, uint, int>)Slot(attributes, 21))(attributes, &key, value));
        private static void SetGuid(nint attributes, Guid key, Guid value) => Check(((delegate* unmanaged[Stdcall]<nint, Guid*, Guid*, int>)Slot(attributes, 24))(attributes, &key, &value));
        internal static void Check(int result) => Marshal.ThrowExceptionForHR(result);
        private static void Release(nint instance) { if (instance != 0) Marshal.Release(instance); }
        public void Dispose() { Release(source); source = 0; }
        [DllImport("mfplat.dll")] private static extern int MFCreateAttributes(out nint attributes, uint size);
        [DllImport("mfplat.dll")] private static extern int MFCreateMediaType(out nint mediaType);
        [DllImport("mfreadwrite.dll", CharSet = CharSet.Unicode)] private static extern int MFCreateSourceReaderFromURL(string path, nint attributes, out nint sourceReader);
    }
}
