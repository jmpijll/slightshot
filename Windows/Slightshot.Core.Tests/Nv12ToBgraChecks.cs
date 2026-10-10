using Slightshot.Core;

internal static class Nv12ToBgraChecks
{
    internal static int Run()
    {
        int checks = 0;
        void Require(bool condition, string message)
        {
            if (!condition) throw new InvalidOperationException("NV12 source conversion: " + message);
            checks++;
        }
        static byte Expected(byte y, byte u, byte v, Nv12Matrix matrix, bool fullRange, int channel)
        {
            double kr = matrix == Nv12Matrix.Bt709 ? 0.2126 : 0.299, kb = matrix == Nv12Matrix.Bt709 ? 0.0722 : 0.114;
            double luma = fullRange ? y : (y - 16) * 255.0 / 219;
            double cb = (u - 128) * (fullRange ? 1 : 255.0 / 224), cr = (v - 128) * (fullRange ? 1 : 255.0 / 224);
            double value = channel switch
            {
                0 => luma + 2 * (1 - kb) * cb,
                1 => luma - 2 * kb * (1 - kb) / (1 - kr - kb) * cb - 2 * kr * (1 - kr) / (1 - kr - kb) * cr,
                _ => luma + 2 * (1 - kr) * cr
            };
            return (byte)Math.Clamp((int)Math.Round(value, MidpointRounding.AwayFromZero), 0, 255);
        }
        var random = new Random(601709);
        foreach (var matrix in new[] { Nv12Matrix.Bt709, Nv12Matrix.Bt601 })
        foreach (bool fullRange in new[] { false, true })
        foreach (int width in new[] { 2, 6, 8, 10, 18, 32, 70 })
        {
            const int height = 6; int stride = width + 10;
            byte[] y = new byte[stride * height + 9], uv = new byte[stride * height / 2 + 9];
            random.NextBytes(y); random.NextBytes(uv);
            // An arbitrary prefix exercises unaligned, cropped native spans;
            // padding between rows is deliberately different from image pixels.
            var luma = y.AsSpan(7); var chroma = uv.AsSpan(5);
            byte[] scalar = new byte[width * height * 4], accelerated = Enumerable.Repeat((byte)0xa5, scalar.Length + 8).ToArray();
            Nv12ToBgra.Convert(luma, chroma, scalar, width, height, stride, matrix, fullRange, false);
            Nv12ToBgra.Convert(luma, chroma, accelerated.AsSpan(4, scalar.Length), width, height, stride, matrix, fullRange, true);
            Require(scalar.AsSpan().SequenceEqual(accelerated.AsSpan(4, scalar.Length)), "SIMD lane order, row pairs and scalar tails produce identical bytes for both matrices/ranges");
            Require(accelerated.AsSpan(0, 4).ToArray().All(value => value == 0xa5) && accelerated.AsSpan(scalar.Length + 4, 4).ToArray().All(value => value == 0xa5), "conversion does not touch output canaries");
            int maximumDelta = 0;
            for (int row = 0; row < height; row++)
            for (int column = 0; column < width; column++)
            {
                int sample = row / 2 * stride + (column & ~1), pixel = (row * width + column) * 4;
                for (int channel = 0; channel < 3; channel++)
                    maximumDelta = Math.Max(maximumDelta, Math.Abs(scalar[pixel + channel] - Expected(luma[row * stride + column], chroma[sample], chroma[sample + 1], matrix, fullRange, channel)));
                if (scalar[pixel + 3] != 255) throw new InvalidOperationException("Source conversion produced nonopaque alpha.");
            }
            Require(maximumDelta <= 1, "mixed chroma, clipping and padded rows match an independent floating-point color reference within one channel level");
        }
        foreach (bool fullRange in new[] { false, true })
        {
            byte[] uv = [128, 128], black = Enumerable.Repeat(fullRange ? (byte)0 : (byte)16, 4).ToArray(), white = Enumerable.Repeat(fullRange ? (byte)255 : (byte)235, 4).ToArray();
            byte[] output = new byte[16];
            Nv12ToBgra.Convert(black, uv, output, 2, 2, 2, Nv12Matrix.Bt709, fullRange);
            Require(output.Where((_, index) => index % 4 != 3).All(value => value == 0), "black maps to RGB zero in the negotiated range");
            Nv12ToBgra.Convert(white, uv, output, 2, 2, 2, Nv12Matrix.Bt709, fullRange);
            Require(output.All(value => value == 255), "white maps to RGB 255 with opaque alpha");
        }
        byte[] storage = new byte[1024];
        Nv12ToBgra.Convert(storage.AsSpan(0, 128), storage.AsSpan(128, 64), storage.AsSpan(256, 512), 8, 16, 8, Nv12Matrix.Bt709, false);
        long allocated = GC.GetAllocatedBytesForCurrentThread();
        for (int repeat = 0; repeat < 20; repeat++)
            Nv12ToBgra.Convert(storage.AsSpan(0, 128), storage.AsSpan(128, 64), storage.AsSpan(256, 512), 8, 16, 8, Nv12Matrix.Bt709, false);
        Require(GC.GetAllocatedBytesForCurrentThread() == allocated, "native-plane conversion allocates no per-frame storage or bookkeeping");
        void Reject(Action operation, string message)
        {
            try { operation(); throw new InvalidOperationException(message); }
            catch (ArgumentException) { checks++; }
        }
        Reject(() => Nv12ToBgra.Convert(new byte[4], new byte[2], new byte[16], 1, 2, 2, Nv12Matrix.Bt709, false), "odd chroma dimensions were accepted");
        Reject(() => Nv12ToBgra.Convert(new byte[3], new byte[2], new byte[16], 2, 2, 2, Nv12Matrix.Bt709, false), "short Y plane was accepted");
        Reject(() => Nv12ToBgra.Convert(new byte[4], new byte[1], new byte[16], 2, 2, 2, Nv12Matrix.Bt709, false), "short UV plane was accepted");
        Reject(() => Nv12ToBgra.Convert(new byte[4], new byte[2], new byte[15], 2, 2, 2, Nv12Matrix.Bt709, false), "short BGRA output was accepted");
        Reject(() => Nv12ToBgra.Convert(storage.AsSpan(0, 4), storage.AsSpan(4, 2), storage.AsSpan(0, 16), 2, 2, 2, Nv12Matrix.Bt709, false), "overlapping source/output planes were accepted");
        Reject(() => Nv12ToBgra.Convert(new byte[4], new byte[2], new byte[16], 2, 2, 2, (Nv12Matrix)4, false), "unsupported HDR matrix was accepted");
        Require(Nv12ColorProfile.ForSdrH264(null, null, null, null) == new Nv12ColorProfile(Nv12Matrix.Bt709, false), "absent matrix/range explicitly use documented own SDR H.264 defaults");
        Require(Nv12ColorProfile.ForSdrH264(0, 0, 0, 0) == new Nv12ColorProfile(Nv12Matrix.Bt709, false), "unknown metadata has the same defaults without resolution heuristics");
        Require(Nv12ColorProfile.ForSdrH264(2, 1, 5, 5) == new Nv12ColorProfile(Nv12Matrix.Bt601, true), "explicit 601 full-range source metadata is honored");
        Require(Nv12ColorProfile.ForSdrH264(1, 2, 2, 5) == new Nv12ColorProfile(Nv12Matrix.Bt709, false), "explicit 709 limited-range source metadata is honored");
        foreach (var unsupported in new (uint Matrix, uint Range, uint Primaries, uint Transfer)[] { (4, 2, 2, 5), (1, 3, 2, 5), (1, 2, 9, 5), (1, 2, 2, 15), (1, 2, 2, 16) })
        {
            try { Nv12ColorProfile.ForSdrH264(unsupported.Matrix, unsupported.Range, unsupported.Primaries, unsupported.Transfer); throw new InvalidOperationException("Unsupported HDR/range metadata was accepted."); }
            catch (NotSupportedException) { checks++; }
        }
        Console.WriteLine($"NV12 source conversion: independent 601/709 full/limited color references, padded planes and exact SIMD/scalar tails passed; AVX2/SSSE3 path available: {System.Runtime.Intrinsics.X86.Avx2.IsSupported && System.Runtime.Intrinsics.X86.Ssse3.IsSupported}.");
        return checks;
    }
}
