using Slightshot.Core;

internal static class VideoAnnotationChecks
{
    internal static int Run()
    {
        int checks = 0;
        void Require(bool condition, string message)
        {
            if (!condition) throw new InvalidOperationException("Video annotations: " + message);
            checks++;
        }
        var duration = TimeSpan.FromSeconds(5);
        var history = new VideoAnnotationHistory(duration);
        var blur = history.Add(new(Tool.Blur, [new(40, 50), new(120, 90)], "#FF3B30", 3, RasterScale: 6));
        Require(blur.Annotation.EffectiveRasterScale == 6, "4K fit-view effect strength is captured per mark");
        Require(new Annotation(Tool.Blur, [], "#FF3B30", 3).EffectiveRasterScale == 1, "screenshot effects retain their default strength");
        foreach (double invalid in new[] { double.NaN, double.PositiveInfinity, 0, -1 })
            Require((blur.Annotation with { RasterScale = invalid }).EffectiveRasterScale == 1, "invalid raster scale safely falls back to screenshot strength");
        Require(blur.Begin == TimeSpan.Zero && blur.End == duration, "a new mark covers the whole clip");
        history.SetTiming(TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(3));
        Require(history.VisibleAt(TimeSpan.FromSeconds(0.999)).Length == 0, "mark is absent before its interval");
        Require(history.VisibleAt(TimeSpan.FromSeconds(1)).Length == 1, "begin includes the first frame");
        Require(history.VisibleAt(TimeSpan.FromSeconds(2.999)).Length == 1, "mark remains through its interval");
        Require(history.VisibleAt(TimeSpan.FromSeconds(3)).Length == 0, "end excludes the next frame");
        Require(history.Selected!.Annotation.Points.SequenceEqual(blur.Annotation.Points), "timing keeps fixed source coordinates");
        var arrow = history.Add(new(Tool.Arrow, [new(200, 20), new(80, 60)], "#0A84FF", 3));
        history.SetTiming(TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(4));
        Require(history.VisibleAt(TimeSpan.FromSeconds(2.5)).Select(item => item.Tool).SequenceEqual(new[] { Tool.Blur, Tool.Arrow }), "overlapping marks preserve drawing order");
        history.Select(blur.Id); history.BeginTimingEdit();
        history.PreviewTiming(TimeSpan.FromSeconds(0.5), TimeSpan.FromSeconds(2.5));
        history.PreviewTiming(TimeSpan.FromSeconds(0.2), TimeSpan.FromSeconds(2));
        history.CommitTimingEdit(); history.Undo();
        Require(history.Selected!.Begin == TimeSpan.FromSeconds(1) && history.Selected.End == TimeSpan.FromSeconds(3), "one undo reverses an entire range drag");
        history.Redo(); Require(history.Selected!.Begin == TimeSpan.FromSeconds(0.2), "redo restores timing");
        Require(history.Selected.Annotation.RasterScale == 6, "timing undo/redo preserves fixed raster strength");
        history.SetTiming(TimeSpan.FromSeconds(-2), TimeSpan.FromSeconds(9));
        Require(history.Selected!.Begin == TimeSpan.Zero && history.Selected.End == duration, "timing clamps to clip bounds");
        history.SetTiming(duration, TimeSpan.Zero);
        Require(history.Selected!.End - history.Selected.Begin == history.MinimumDuration && history.Selected.End == duration, "crossed handles retain a nonempty interval");
        history.Select(arrow.Id); history.DeleteSelected();
        Require(history.Items.Count == 1 && history.SelectedId == blur.Id, "deleting selects the adjacent mark");
        history.Undo(); Require(history.Items.Count == 2 && history.SelectedId == arrow.Id, "undo restores deletion and selection");
        var snapshot = history.ExportSnapshot(); snapshot[0].Annotation.Points[0] = new(999, 999);
        Require(snapshot[0].Annotation.RasterScale == 6, "export snapshots preserve raster strength");
        Require(history.Items[0].Annotation.Points[0] == new PointD(40, 50), "export snapshot owns its point arrays");
        history.Undo(); history.Add(new(Tool.Text, [new(10, 10)], "#FFFFFF", 3, Text: "New"));
        Require(!history.CanRedo, "a new edit clears redo");
        Require(history.VisibleAt(duration).Length == 0, "no marks leak beyond the clip");
        return checks;
    }
}
