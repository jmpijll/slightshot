namespace Slightshot.Core;

public readonly record struct Nv12ColorProfile(Nv12Matrix Matrix, bool FullRange)
{
    // Interpret negotiated MF enums for Slightshot's own SDR H.264 recordings.
    // MF mandates unknown matrix→709; H.264's absent full-range flag→limited.
    // Explicit full range and 601 remain supported without resolution guesses.
    public static Nv12ColorProfile ForSdrH264(uint? matrix, uint? range, uint? primaries, uint? transfer)
    {
        Nv12Matrix effectiveMatrix = matrix.GetValueOrDefault() switch
        {
            0 or 1 => Nv12Matrix.Bt709,
            2 => Nv12Matrix.Bt601,
            _ => throw new NotSupportedException("This recording has unsupported HDR or wide-gamut YUV matrix metadata.")
        };
        bool fullRange = range.GetValueOrDefault() switch
        {
            0 or 2 => false,
            1 => true,
            _ => throw new NotSupportedException("This recording has unsupported video nominal range metadata.")
        };
        if (primaries is > 8 || transfer is not (null or 0 or 4 or 5 or 7))
            throw new NotSupportedException("This recording has unsupported HDR, wide-gamut or transfer-function metadata.");
        return new(effectiveMatrix, fullRange);
    }
}
