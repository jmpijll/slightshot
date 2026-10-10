using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Runtime.Intrinsics;
using System.Runtime.Intrinsics.X86;

namespace Slightshot.Core;

// Full-range opaque BGRA → limited-range BT.709 NV12. The top-down Y plane
// is followed by U,V pairs averaged over each 2×2 source block. Fixed-point
// coefficients follow the Microsoft 8-bit YUV conversion equations.
public static class BgraToNv12
{
    public static void Convert(ReadOnlySpan<byte> source, Span<byte> output, int width, int height) => Convert(source, output, width, height, true);

    internal static void Convert(ReadOnlySpan<byte> source, Span<byte> output, int width, int height, bool vectorized)
    {
        if (width <= 0 || height <= 0 || (width & 1) != 0 || (height & 1) != 0) throw new ArgumentOutOfRangeException(nameof(width));
        int area = checked(width * height);
        if (source.Length < checked(area * 4) || output.Length < checked(area + area / 2)) throw new ArgumentException("Pixel buffers do not match the conversion dimensions.");
        var pixels = MemoryMarshal.Cast<byte, uint>(source);
        ref uint first = ref MemoryMarshal.GetReference(pixels);
        var mask = Vector256.Create(255u);
        for (int y = 0; y < height; y += 2)
        {
            int top = y * width, bottom = top + width, chroma = area + y / 2 * width, x = 0;
            if (vectorized && Avx2.IsSupported && Sse41.IsSupported)
            {
                for (; x <= width - 8; x += 8)
                {
                    var a = Vector256.LoadUnsafe(ref first, (nuint)(top + x));
                    var b = Vector256.LoadUnsafe(ref first, (nuint)(bottom + x));
                    WriteLuma(a, output, top + x); WriteLuma(b, output, bottom + x);
                    var red = SumBlocks(Avx2.And(Avx2.ShiftRightLogical(a, 16), mask), Avx2.And(Avx2.ShiftRightLogical(b, 16), mask));
                    var green = SumBlocks(Avx2.And(Avx2.ShiftRightLogical(a, 8), mask), Avx2.And(Avx2.ShiftRightLogical(b, 8), mask));
                    var blue = SumBlocks(Avx2.And(a, mask), Avx2.And(b, mask));
                    var u = Chroma(red, green, blue, -6596, -22189, 28784);
                    var v = Chroma(red, green, blue, 28784, -26145, -2639);
                    var uv = Sse2.UnpackLow(Sse2.PackSignedSaturate(u, Vector128<int>.Zero), Sse2.PackSignedSaturate(v, Vector128<int>.Zero));
                    var bytes = Sse2.PackUnsignedSaturate(uv, Vector128<short>.Zero);
                    Unsafe.WriteUnaligned(ref output[chroma + x], bytes.AsUInt64().GetElement(0));
                }
            }
            for (; x < width; x += 2)
            {
                uint a = pixels[top + x], b = pixels[top + x + 1], c = pixels[bottom + x], d = pixels[bottom + x + 1];
                output[top + x] = Luma(a); output[top + x + 1] = Luma(b);
                output[bottom + x] = Luma(c); output[bottom + x + 1] = Luma(d);
                int red = ChannelSum(a, b, c, d, 16), green = ChannelSum(a, b, c, d, 8), blue = ChannelSum(a, b, c, d, 0);
                output[chroma + x] = (byte)((-6596 * red - 22189 * green + 28784 * blue + 33685504) >> 18);
                output[chroma + x + 1] = (byte)((28784 * red - 26145 * green - 2639 * blue + 33685504) >> 18);
            }
        }
    }
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static int ChannelSum(uint a, uint b, uint c, uint d, int shift) => (int)(((a >> shift) & 255) + ((b >> shift) & 255) + ((c >> shift) & 255) + ((d >> shift) & 255));
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static byte Luma(uint pixel) => (byte)((11966 * ((pixel >> 16) & 255) + 40254 * ((pixel >> 8) & 255) + 4064 * (pixel & 255) + 32768) / 65536 + 16);
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static Vector128<int> SumBlocks(Vector256<uint> a, Vector256<uint> b)
    {
        var sums = Avx2.HorizontalAdd(Avx2.Add(a, b).AsInt32(), Vector256<int>.Zero);
        return Sse2.UnpackLow(sums.GetLower().AsInt64(), sums.GetUpper().AsInt64()).AsInt32();
    }
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static Vector128<int> Chroma(Vector128<int> r, Vector128<int> g, Vector128<int> b, int cr, int cg, int cb)
    {
        var sum = Sse2.Add(Sse2.Add(Sse41.MultiplyLow(r, Vector128.Create(cr)), Sse41.MultiplyLow(g, Vector128.Create(cg))), Sse41.MultiplyLow(b, Vector128.Create(cb)));
        return Sse2.ShiftRightArithmetic(Sse2.Add(sum, Vector128.Create(33685504)), 18);
    }
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static void WriteLuma(Vector256<uint> pixels, Span<byte> output, int offset)
    {
        var mask = Vector256.Create(255u);
        var r = Avx2.And(Avx2.ShiftRightLogical(pixels, 16), mask).AsInt32();
        var g = Avx2.And(Avx2.ShiftRightLogical(pixels, 8), mask).AsInt32();
        var b = Avx2.And(pixels, mask).AsInt32();
        var sum = Avx2.Add(Avx2.Add(Avx2.MultiplyLow(r, Vector256.Create(11966)), Avx2.MultiplyLow(g, Vector256.Create(40254))), Avx2.MultiplyLow(b, Vector256.Create(4064)));
        var values = Avx2.Add(Avx2.ShiftRightLogical(Avx2.Add(sum, Vector256.Create(32768)).AsUInt32(), 16), Vector256.Create(16u)).AsInt32();
        var words = Sse2.PackSignedSaturate(values.GetLower(), values.GetUpper());
        Unsafe.WriteUnaligned(ref output[offset], Sse2.PackUnsignedSaturate(words, Vector128<short>.Zero).AsUInt64().GetElement(0));
    }
}
