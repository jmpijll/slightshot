using System.Buffers.Binary;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Runtime.Intrinsics;
using System.Runtime.Intrinsics.X86;

namespace Slightshot.Core;

public enum Nv12Matrix { Bt709 = 1, Bt601 = 2 }

// Native top-down NV12 planes → opaque full-range BGRA. Consume the validated
// native spans while locked, without copying/allocating another source frame.
public static class Nv12ToBgra
{
    public static void Convert(ReadOnlySpan<byte> luma, ReadOnlySpan<byte> chroma, Span<byte> output, int width, int height,
        int stride, Nv12Matrix matrix, bool fullRange) => Convert(luma, chroma, output, width, height, stride, matrix, fullRange, true);

    internal static void Convert(ReadOnlySpan<byte> luma, ReadOnlySpan<byte> chroma, Span<byte> output, int width, int height,
        int stride, Nv12Matrix matrix, bool fullRange, bool vectorized)
    {
        if (width <= 0 || height <= 0 || (width & 1) != 0 || (height & 1) != 0 || stride < width) throw new ArgumentOutOfRangeException(nameof(width));
        if (luma.Length < checked((height - 1) * stride + width) || chroma.Length < checked((height / 2 - 1) * stride + width)
            || output.Length < checked(width * height * 4)) throw new ArgumentException("NV12 planes do not match the visible conversion dimensions.");
        if (luma.Overlaps(output) || chroma.Overlaps(output)) throw new ArgumentException("Source planes and output pixels must have distinct storage.");
        var coefficients = (matrix, fullRange) switch
        {
            (Nv12Matrix.Bt709, false) => new Coefficients(76309, 117489, 13975, 34925, 138438, 16),
            (Nv12Matrix.Bt709, true) => new Coefficients(65536, 103206, 12276, 30679, 121609, 0),
            (Nv12Matrix.Bt601, false) => new Coefficients(76309, 104597, 25675, 53279, 132201, 16),
            (Nv12Matrix.Bt601, true) => new Coefficients(65536, 91881, 22553, 46802, 116130, 0),
            _ => throw new ArgumentOutOfRangeException(nameof(matrix))
        };
        var pixels = MemoryMarshal.Cast<byte, uint>(output);
        var uShuffle = Vector128.Create((byte)0, 0, 2, 2, 4, 4, 6, 6, 128, 128, 128, 128, 128, 128, 128, 128);
        var vShuffle = Vector128.Create((byte)1, 1, 3, 3, 5, 5, 7, 7, 128, 128, 128, 128, 128, 128, 128, 128);
        for (int row = 0; row < height; row += 2)
        {
            int top = row * stride, bottom = top + stride, uv = row / 2 * stride, outputTop = row * width, x = 0;
            if (vectorized && Avx2.IsSupported && Ssse3.IsSupported)
            {
                for (; x <= width - 8; x += 8)
                {
                    var packed = Vector128.Create(BinaryPrimitives.ReadUInt64LittleEndian(chroma.Slice(uv + x, 8)), 0UL).AsByte();
                    var u = Avx2.Subtract(Avx2.ConvertToVector256Int32(Ssse3.Shuffle(packed, uShuffle)), Vector256.Create(128));
                    var v = Avx2.Subtract(Avx2.ConvertToVector256Int32(Ssse3.Shuffle(packed, vShuffle)), Vector256.Create(128));
                    var red = Avx2.MultiplyLow(v, Vector256.Create(coefficients.RedV));
                    var green = Avx2.Subtract(Vector256<int>.Zero, Avx2.Add(Avx2.MultiplyLow(u, Vector256.Create(coefficients.GreenU)), Avx2.MultiplyLow(v, Vector256.Create(coefficients.GreenV))));
                    var blue = Avx2.MultiplyLow(u, Vector256.Create(coefficients.BlueU));
                    WriteVector(luma.Slice(top + x, 8), pixels, outputTop + x, coefficients, red, green, blue);
                    WriteVector(luma.Slice(bottom + x, 8), pixels, outputTop + width + x, coefficients, red, green, blue);
                }
            }
            for (; x < width; x += 2)
            {
                int u = chroma[uv + x] - 128, v = chroma[uv + x + 1] - 128;
                int red = v * coefficients.RedV, green = -u * coefficients.GreenU - v * coefficients.GreenV, blue = u * coefficients.BlueU;
                pixels[outputTop + x] = Pixel(luma[top + x], coefficients, red, green, blue);
                pixels[outputTop + x + 1] = Pixel(luma[top + x + 1], coefficients, red, green, blue);
                pixels[outputTop + width + x] = Pixel(luma[bottom + x], coefficients, red, green, blue);
                pixels[outputTop + width + x + 1] = Pixel(luma[bottom + x + 1], coefficients, red, green, blue);
            }
        }
    }
    private readonly record struct Coefficients(int Luma, int RedV, int GreenU, int GreenV, int BlueU, int Offset);
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static uint Pixel(byte y, Coefficients coefficients, int red, int green, int blue)
    {
        int luma = (y - coefficients.Offset) * coefficients.Luma + 32768;
        return 0xff000000u | ((uint)Math.Clamp((luma + red) >> 16, 0, 255) << 16)
            | ((uint)Math.Clamp((luma + green) >> 16, 0, 255) << 8) | (uint)Math.Clamp((luma + blue) >> 16, 0, 255);
    }
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static void WriteVector(ReadOnlySpan<byte> luma, Span<uint> output, int offset, Coefficients coefficients,
        Vector256<int> red, Vector256<int> green, Vector256<int> blue)
    {
        var y = Avx2.ConvertToVector256Int32(Vector128.Create(BinaryPrimitives.ReadUInt64LittleEndian(luma), 0UL).AsByte());
        var scaled = Avx2.Add(Avx2.MultiplyLow(Avx2.Subtract(y, Vector256.Create(coefficients.Offset)), Vector256.Create(coefficients.Luma)), Vector256.Create(32768));
        static Vector256<int> Channel(Vector256<int> value) => Avx2.Min(Avx2.Max(Avx2.ShiftRightArithmetic(value, 16), Vector256<int>.Zero), Vector256.Create(255));
        var r = Channel(Avx2.Add(scaled, red)); var g = Channel(Avx2.Add(scaled, green)); var b = Channel(Avx2.Add(scaled, blue));
        var packed = Avx2.Or(Avx2.Or(Avx2.ShiftLeftLogical(r, 16), Avx2.ShiftLeftLogical(g, 8)), Avx2.Or(b, Vector256.Create(unchecked((int)0xff000000))));
        packed.AsUInt32().StoreUnsafe(ref MemoryMarshal.GetReference(output), (nuint)offset);
    }
}
