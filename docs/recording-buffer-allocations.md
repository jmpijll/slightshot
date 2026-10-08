# Windows recording frame storage

Measured with the Release .NET 10 core checks on 8 October 2026. Run:

```sh
dotnet run --project Windows/Slightshot.Core.Tests -c Release
```

The old capture path created a fresh `3840 × 2160 × 4` byte array for each
BGRA frame. Thirty successive allocations measured **995,328,720 bytes**,
including array headers. Renting and releasing thirty warmed frames measured
**3,600 bytes**, a **99.9996% reduction** for this storage operation. The small
remaining allocations are frame ownership objects and waiter notifications.
This isolates the managed frame-array hotspot; it is not an encoder throughput,
latency, process resident-memory or full recording allocation benchmark.

Each session now allocates at most four exact-sized arrays, lazily. At 4K this
limits managed pixel storage to **132,710,400 bytes (126.56 MiB)**. The native
DIB and Windows encoder also own memory, outside this bound. A fifth live frame
waits with Stop cancellation instead of adding a queued pixel array.

Capture still copies the same top-down GDI DIB into BGRA storage and sets every
alpha byte to 255. Ownership transfers to the media sample before its request
is completed. The array returns only from
[`MediaStreamSample.Processed`](https://learn.microsoft.com/en-us/uwp/api/windows.media.core.mediastreamsample.processed?view=winrt-26100),
Microsoft's documented safe buffer reuse point. Closing clears idle storage;
late processing callbacks discard their arrays without reopening the pool.
Shutdown cancels pending frame requests and drains admitted capture callbacks
before releasing the DIB and cancellation resources.

The core checks cover distinct outstanding pixels, the four-frame bound,
reuse only after release, duplicate release, cancellation without consuming a
later buffer, closure with a blocked request, and concurrent release/closure.
The existing native recording smoke test adds a six-second encode/decode soak
with changing red/blue/green frames, a maximum of four distinct arrays, repeated
Stop, three abort/dispose cycles, capture failure and cancellation before startup.
It runs both the normal build and the extracted portable executable in Windows
CI. It uses synthetic frames and real native media; live GDI desktop capture
and cursor exclusion still require the maintainer's desktop check.
