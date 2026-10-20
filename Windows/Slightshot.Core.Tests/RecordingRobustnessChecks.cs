using Slightshot.Core;

internal static class RecordingRobustnessChecks
{
    internal static int Run()
    {
        int checks = 0;
        void Equal<T>(T expected, T actual, string message)
        {
            if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new InvalidOperationException($"{message}: expected {expected}, got {actual}");
            checks++;
        }

        Equal(new RecordingGeometry(800, 450, 800, 450), RecordingGeometry.Create(801, 451, 801, 451), "odd native area drops its last column and row instead of resampling");
        Equal(true, RecordingGeometry.Create(801, 451, 801, 451).IsPixelExact, "cropped odd area is captured pixel for pixel");
        Equal(new RecordingGeometry(1920, 1080, 1920, 1080), RecordingGeometry.Create(1920, 1080, 1920, 1080), "even area is unchanged");
        Equal(new RecordingGeometry(502, 376, 502, 376), RecordingGeometry.Create(502, 377, 502, 377), "only the odd axis is cropped");
        Equal(new RecordingGeometry(800, 600, 400, 300), RecordingGeometry.Create(800, 600, 400, 300), "point-resolution recording still downsamples HiDPI pixels");
        Equal(new RecordingGeometry(1003, 753, 802, 602), RecordingGeometry.Create(1003, 753, 802, 602), "fractional display scale keeps the full source and resamples");
        Equal(new RecordingGeometry(5121, 2881, 4096, 2304), RecordingGeometry.Create(5121, 2881, 5121, 2881), "areas beyond the encoder cap keep their full source");
        Equal(new RecordingGeometry(1, 1, 2, 2), RecordingGeometry.Create(1, 1, 1, 1), "a one-pixel area is enlarged to the encoder minimum");
        Equal(false, RecordingGeometry.Create(1, 1, 1, 1).IsPixelExact, "encoder minimum is not reported as pixel exact");

        var young = TimeSpan.FromSeconds(5); var old = TimeSpan.FromHours(3);
        Equal(RecordingDirectoryState.Live, RecordingDirectories.Classify(RecordingOwner.Running, keep: false, old), "a locked owner is a live session");
        Equal(RecordingDirectoryState.Live, RecordingDirectories.Classify(RecordingOwner.Running, keep: true, old), "a live session that asked to be kept is not adopted");
        Equal(RecordingDirectoryState.Stale, RecordingDirectories.Classify(RecordingOwner.Exited, keep: false, young), "an exited owner leaves a stale directory");
        Equal(RecordingDirectoryState.Recoverable, RecordingDirectories.Classify(RecordingOwner.Exited, keep: true, old), "a kept recording from an ended session is offered again");
        Equal(RecordingDirectoryState.Live, RecordingDirectories.Classify(RecordingOwner.Missing, keep: false, young), "a directory still being created is left alone");
        Equal(RecordingDirectoryState.Stale, RecordingDirectories.Classify(RecordingOwner.Missing, keep: false, old), "a directory from an older version without an owner lock is stale");
        return checks;
    }
}
