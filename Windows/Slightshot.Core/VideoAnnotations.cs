namespace Slightshot.Core;

// Video marks retain source-pixel coordinates. End is exclusive, so adjacent
// intervals never show an extra frame of a mark that has already ended.
public sealed record TimedAnnotation(Guid Id, Annotation Annotation, TimeSpan Begin, TimeSpan End)
{
    public bool IsVisible(TimeSpan position) => position >= Begin && position < End;
}

// The kept part of the source recording. End is exclusive like annotation
// intervals, and exported time zero is Start.
public readonly record struct VideoTrim(TimeSpan Start, TimeSpan End)
{
    public static VideoTrim Whole(TimeSpan duration) => new(TimeSpan.Zero, duration);
    public TimeSpan Length => End - Start;
    public TimeSpan Clamp(TimeSpan position) => TimeSpan.FromTicks(Math.Clamp(position.Ticks, Start.Ticks, End.Ticks));
    public VideoTrim Within(TimeSpan duration)
    {
        long start = Math.Clamp(Start.Ticks, 0, duration.Ticks);
        return new(TimeSpan.FromTicks(start), TimeSpan.FromTicks(Math.Clamp(End.Ticks, start, duration.Ticks)));
    }

    // Annotations keep source times while editing, so widening the trim again
    // restores them. Export sees only the overlap, moved onto its own timeline.
    public TimedAnnotation[] Clip(IEnumerable<TimedAnnotation> annotations)
    {
        var trim = this;
        return annotations.Where(item => item.Begin < trim.End && item.End > trim.Start)
            .Select(item => item with { Begin = trim.Clamp(item.Begin) - trim.Start, End = trim.Clamp(item.End) - trim.Start })
            .ToArray();
    }
}

public sealed record VideoEdit(IReadOnlyList<TimedAnnotation> Annotations, VideoTrim Trim);

public sealed class VideoAnnotationHistory
{
    private sealed record State(TimedAnnotation[] Items, Guid? Selected, VideoTrim Trim);
    private readonly Stack<State> undo = [];
    private readonly Stack<State> redo = [];
    private readonly List<TimedAnnotation> items = [];
    private State? timingBefore;
    public TimeSpan Duration { get; }
    public TimeSpan MinimumDuration => TimeSpan.FromTicks(Math.Min(Duration.Ticks, TimeSpan.TicksPerSecond / 30));
    public IReadOnlyList<TimedAnnotation> Items => items;
    public Guid? SelectedId { get; private set; }
    public VideoTrim Trim { get; private set; }
    public TimedAnnotation? Selected => items.FirstOrDefault(item => item.Id == SelectedId);
    public bool CanUndo => undo.Count > 0;
    public bool CanRedo => redo.Count > 0;

    public VideoAnnotationHistory(TimeSpan duration)
    {
        if (duration <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(duration));
        Duration = duration; Trim = VideoTrim.Whole(duration);
    }

    public TimedAnnotation Add(Annotation annotation)
    {
        CommitTimingEdit(); Remember();
        var item = new TimedAnnotation(Guid.NewGuid(), annotation, TimeSpan.Zero, Duration);
        items.Add(item); SelectedId = item.Id; return item;
    }

    public void Select(Guid? id)
    {
        CommitTimingEdit(); SelectedId = items.Any(item => item.Id == id) ? id : null;
    }

    public bool DeleteSelected()
    {
        CommitTimingEdit();
        int index = items.FindIndex(item => item.Id == SelectedId);
        if (index < 0) return false;
        Remember(); items.RemoveAt(index);
        SelectedId = items.Count > 0 ? items[Math.Min(index, items.Count - 1)].Id : null;
        return true;
    }

    // A range drag produces one undo step, regardless of pointer event count.
    // Annotation timing and trim drags share this pending step.
    public void BeginTimingEdit()
    {
        if (Selected != null) timingBefore ??= Snapshot();
    }

    public void BeginTrimEdit() => timingBefore ??= Snapshot();

    public void PreviewTrim(TimeSpan start, TimeSpan end)
    {
        BeginTrimEdit();
        long first = Math.Clamp(start.Ticks, 0, Duration.Ticks - MinimumDuration.Ticks);
        Trim = new(TimeSpan.FromTicks(first), TimeSpan.FromTicks(Math.Clamp(end.Ticks, first + MinimumDuration.Ticks, Duration.Ticks)));
    }

    public void SetTrim(TimeSpan start, TimeSpan end)
    {
        PreviewTrim(start, end); CommitTimingEdit();
    }

    // A typed end follows the drag rule: it stops one minimum length short of
    // the other end, which never moves.
    public void SetTrimStart(double seconds)
    {
        if (seconds == Trim.Start.TotalSeconds) return;
        SetTrim(TimeSpan.FromTicks((long)Math.Clamp(RoundedTrimTicks(seconds), 0, Trim.End.Ticks - MinimumDuration.Ticks)), Trim.End);
    }

    public void SetTrimEnd(double seconds)
    {
        if (seconds == Trim.End.TotalSeconds) return;
        SetTrim(Trim.Start, TimeSpan.FromTicks((long)Math.Clamp(RoundedTrimTicks(seconds), Trim.Start.Ticks + MinimumDuration.Ticks, Duration.Ticks)));
    }

    private decimal RoundedTrimTicks(double seconds)
    {
        if (!double.IsFinite(seconds)) throw new ArgumentOutOfRangeException(nameof(seconds));
        decimal bounded = (decimal)Math.Clamp(seconds, -1, Duration.TotalSeconds + 1);
        return Math.Round(bounded, 2, MidpointRounding.AwayFromZero) * TimeSpan.TicksPerSecond;
    }

    public void PreviewTiming(TimeSpan begin, TimeSpan end)
    {
        int index = items.FindIndex(item => item.Id == SelectedId);
        if (index < 0) return;
        BeginTimingEdit();
        long start = Math.Clamp(begin.Ticks, 0, Duration.Ticks - MinimumDuration.Ticks);
        long finish = Math.Clamp(end.Ticks, start + MinimumDuration.Ticks, Duration.Ticks);
        items[index] = items[index] with { Begin = TimeSpan.FromTicks(start), End = TimeSpan.FromTicks(finish) };
    }

    public void CommitTimingEdit()
    {
        if (timingBefore is not { } previous) return;
        timingBefore = null;
        if (previous.Items.SequenceEqual(items) && previous.Trim == Trim) return;
        undo.Push(previous); redo.Clear();
    }

    public void SetTiming(TimeSpan begin, TimeSpan end)
    {
        PreviewTiming(begin, end); CommitTimingEdit();
    }

    public bool Undo()
    {
        CommitTimingEdit();
        if (!undo.TryPop(out var previous)) return false;
        redo.Push(Snapshot()); Restore(previous); return true;
    }

    public bool Redo()
    {
        CommitTimingEdit();
        if (!redo.TryPop(out var next)) return false;
        undo.Push(Snapshot()); Restore(next); return true;
    }

    public Annotation[] VisibleAt(TimeSpan position)
        => items.Where(item => item.IsVisible(position)).Select(item => item.Annotation).ToArray();

    public TimedAnnotation[] ExportSnapshot()
    {
        CommitTimingEdit();
        // Keep the export independent of later UI interaction and callers that
        // mutate a stroke's point array after adding it to history.
        return items.Select(item => item with { Annotation = item.Annotation with { Points = item.Annotation.Points.ToArray() } }).ToArray();
    }

    private State Snapshot() => new(items.ToArray(), SelectedId, Trim);
    private void Remember() { undo.Push(Snapshot()); redo.Clear(); }
    private void Restore(State state) { items.Clear(); items.AddRange(state.Items); SelectedId = state.Selected; Trim = state.Trim; }
}
