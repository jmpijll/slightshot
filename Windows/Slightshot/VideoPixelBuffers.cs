using Slightshot.Core;

namespace Slightshot;

internal static class VideoPixelBuffers
{
    // Three distinct source-sized BGRA buffers: current, lookahead and mutable
    // composition. Three 4K buffers use 94.9 MiB; total idle retention is capped
    // at 100 MiB, and a single buffer above that limit is never cached.
    internal static readonly ExactSizeBufferPool Shared = new(3, 100L * 1024 * 1024);
}
