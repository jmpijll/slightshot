using Slightshot.Core;

internal static class VideoTrimChecks
{
    internal static int Run()
    {
        int checks = 0;
        void Require(bool condition, string message)
        {
            if (!condition) throw new InvalidOperationException("Video trim: " + message);
            checks++;
        }
        TimeSpan Seconds(double value) => TimeSpan.FromTicks((long)Math.Round(value * TimeSpan.TicksPerSecond));
        var duration = Seconds(5);
        var history = new VideoAnnotationHistory(duration);
        Require(history.Trim == VideoTrim.Whole(duration) && !history.CanUndo, "a new recording keeps its whole length without an undo step");

        var blur = history.Add(new(Tool.Blur, [new(40, 50), new(120, 90)], "#FF3B30", 3));
        history.SetTiming(Seconds(1), Seconds(3));
        var arrow = history.Add(new(Tool.Arrow, [new(200, 20), new(80, 60)], "#0A84FF", 3));
        history.SetTiming(Seconds(4), Seconds(4.5));
        var marks = history.ExportSnapshot();

        history.BeginTrimEdit();
        history.PreviewTrim(Seconds(0.5), Seconds(4));
        history.PreviewTrim(Seconds(2), Seconds(3.5));
        history.CommitTimingEdit();
        Require(history.Trim == new VideoTrim(Seconds(2), Seconds(3.5)) && history.Trim.Length == Seconds(1.5), "a trim drag sets both ends");
        Require(history.ExportSnapshot().SequenceEqual(marks, new SameTiming()), "trimming keeps annotation source times");
        history.Undo();
        Require(history.Trim == VideoTrim.Whole(duration), "one undo reverses an entire trim drag");
        history.Redo();
        Require(history.Trim == new VideoTrim(Seconds(2), Seconds(3.5)), "redo restores the trim");

        history.SetTrim(Seconds(-1), Seconds(9));
        Require(history.Trim == VideoTrim.Whole(duration), "trim clamps to the recording");
        history.SetTrim(duration, TimeSpan.Zero);
        Require(history.Trim.Length == history.MinimumDuration && history.Trim.End == duration, "crossed trim handles keep one frame");
        var exact = TimeSpan.FromTicks(31_234_567);
        history.SetTrim(Seconds(1), exact);
        Require(history.Trim == new VideoTrim(Seconds(1), exact), "trim keeps exact endpoint ticks");

        int undoable = 0; while (history.Undo()) undoable++;
        Require(history.Trim == VideoTrim.Whole(duration) && history.Items.Count == 0, "undo walks back through trims and annotations in order");
        while (history.Redo()) undoable--;
        Require(undoable == 0 && history.Trim == new VideoTrim(Seconds(1), exact) && history.Items.Count == 2, "redo replays the same trims and annotations");
        history.SetTrim(Seconds(1), exact);
        history.Undo();
        Require(history.Trim != new VideoTrim(Seconds(1), exact), "setting an unchanged trim adds no undo step");
        history.Redo();

        var typed = new VideoAnnotationHistory(duration);
        typed.SetTrim(Seconds(1), Seconds(3));
        typed.SetTrimStart(4);
        Require(typed.Trim == new VideoTrim(Seconds(3) - typed.MinimumDuration, Seconds(3)), "a typed start past the end stops one minimum length before it and leaves the end alone");
        typed.SetTrimEnd(0.5);
        Require(typed.Trim == new VideoTrim(Seconds(3) - typed.MinimumDuration, Seconds(3)), "a typed end before the start leaves the start alone");
        typed.Undo();
        typed.SetTrimEnd(0.5);
        Require(typed.Trim == new VideoTrim(Seconds(1), Seconds(1) + typed.MinimumDuration), "a typed end before the start stops one minimum length after it");
        typed.SetTrimStart(-3); typed.SetTrimEnd(60);
        Require(typed.Trim == VideoTrim.Whole(duration), "typed ends clamp to the recording");
        typed.SetTrimStart(exact.TotalSeconds);
        Require(typed.Trim == new VideoTrim(Seconds(3.12), duration), "a typed start rounds to hundredths and keeps the end");
        typed.SetTrimStart(1.005); typed.SetTrimEnd(3.125);
        Require(typed.Trim == new VideoTrim(Seconds(1.01), Seconds(3.13)), "typed half hundredths round away from zero");
        typed.SetTrimStart(3.104);
        Require(typed.Trim == new VideoTrim(Seconds(3.13) - typed.MinimumDuration, Seconds(3.13)), "typed rounding happens before the minimum-length clamp and preserves its off-grid boundary");
        typed.SetTrimStart(typed.Trim.Start.TotalSeconds);
        Require(typed.Trim.Start == Seconds(3.13) - typed.MinimumDuration, "committing an unchanged off-grid minimum boundary preserves its exact value");
        typed.SetTrimEnd(double.MaxValue); typed.SetTrimStart(double.MinValue);
        Require(typed.Trim == VideoTrim.Whole(duration), "extreme finite typed values clamp without overflowing rounded ticks");
        var offGrid = new VideoAnnotationHistory(exact);
        offGrid.SetTrimEnd(2); offGrid.SetTrimEnd(9);
        Require(offGrid.Trim.End == exact, "typed ends beyond the recording preserve its exact off-grid duration");
        offGrid.Undo(); offGrid.Undo();
        offGrid.SetTrimEnd(exact.TotalSeconds);
        Require(!offGrid.CanUndo && offGrid.CanRedo && offGrid.Trim.End == exact, "an unchanged exact source end keeps Redo without rounding");

        var redoable = new VideoAnnotationHistory(duration);
        redoable.SetTrim(Seconds(1), Seconds(4)); redoable.Undo();
        redoable.BeginTrimEdit(); redoable.CommitTimingEdit();
        Require(redoable.CanRedo && !redoable.CanUndo, "clicking a trim handle without moving it keeps Redo");
        redoable.BeginTrimEdit(); redoable.PreviewTrim(Seconds(2), Seconds(3)); redoable.PreviewTrim(TimeSpan.Zero, duration); redoable.CommitTimingEdit();
        Require(redoable.CanRedo && !redoable.CanUndo, "a trim drag that returns to where it started keeps Redo");
        redoable.SetTrimStart(0); redoable.SetTrimEnd(duration.TotalSeconds); redoable.SetTrim(TimeSpan.Zero, duration);
        Require(redoable.CanRedo && !redoable.CanUndo, "typing or resetting an unchanged trim keeps Redo");
        redoable.SetTrimStart(0.004); redoable.SetTrimEnd(5.004);
        Require(redoable.CanRedo && !redoable.CanUndo, "typed values that round to the unchanged trim keep Redo");
        redoable.Redo();
        Require(redoable.Trim == new VideoTrim(Seconds(1), Seconds(4)), "Redo still restores the trim after no-op edits");

        history.Select(blur.Id); history.DeleteSelected(); history.Undo();
        Require(history.Trim == new VideoTrim(Seconds(1), exact), "annotation undo leaves the trim alone");

        var trim = new VideoTrim(Seconds(2), Seconds(3.5));
        var clipped = trim.Clip(marks);
        Require(clipped.Length == 1 && clipped[0].Id == blur.Id, "annotations wholly outside the trim are left out of the export");
        Require(clipped[0].Begin == TimeSpan.Zero && clipped[0].End == Seconds(1), "a partly kept annotation is clipped and moved to the exported timeline");
        Require(clipped[0].Annotation.Points.SequenceEqual(blur.Annotation.Points), "clipping keeps source coordinates");
        var inside = new VideoTrim(Seconds(0.5), Seconds(4.25)).Clip(marks);
        Require(inside[0].Begin == Seconds(0.5) && inside[0].End == Seconds(2.5) && inside[1].Begin == Seconds(3.5) && inside[1].End == Seconds(3.75), "trimmed annotation times shift by the trim start and end at the trim end");
        Require(VideoTrim.Whole(duration).Clip(marks).SequenceEqual(marks), "an untrimmed export keeps every annotation unchanged");
        Require(new VideoTrim(Seconds(3), Seconds(4)).Clip(marks).Length == 0, "an annotation ending at the trim start is not exported");
        Require(new VideoTrim(Seconds(0), Seconds(1)).Clip(marks).Length == 0, "an annotation starting at the trim end is not exported");
        Require(new VideoTrim(Seconds(2.9), Seconds(4.1)).Clip(marks).Select(item => item.Id).SequenceEqual(new[] { blur.Id, arrow.Id }), "clipping keeps drawing order");

        Require(trim.Clamp(Seconds(1)) == Seconds(2) && trim.Clamp(Seconds(4)) == Seconds(3.5) && trim.Clamp(Seconds(2.5)) == Seconds(2.5), "playhead positions clamp into the trim");
        Require(new VideoTrim(Seconds(2), Seconds(9)).Within(duration) == new VideoTrim(Seconds(2), duration), "export clamps a trim to the decoded duration");
        Require(new VideoTrim(Seconds(7), Seconds(9)).Within(duration).Length == TimeSpan.Zero, "a trim past the decoded end is empty");
        return checks;
    }

    private sealed class SameTiming : IEqualityComparer<TimedAnnotation>
    {
        public bool Equals(TimedAnnotation? first, TimedAnnotation? second) => first?.Id == second?.Id && first?.Begin == second?.Begin && first?.End == second?.End;
        public int GetHashCode(TimedAnnotation item) => item.Id.GetHashCode();
    }
}
