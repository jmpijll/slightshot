using System.Collections;

namespace Slightshot.Core;

// Only committed marks enter history. Restoring the same objects in order keeps
// text styling, numbered steps and effects over earlier marks intact.
public sealed class AnnotationHistory : IReadOnlyList<Annotation>
{
    private readonly List<Annotation> committed = [];
    private readonly Stack<Annotation> undone = [];
    public int Count => committed.Count;
    public Annotation this[int index] => committed[index];
    public bool CanUndo => committed.Count > 0;
    public bool CanRedo => undone.Count > 0;

    public void Add(Annotation annotation)
    {
        committed.Add(annotation);
        undone.Clear();
    }

    public void AddRange(IEnumerable<Annotation> annotations)
    {
        foreach (var annotation in annotations) Add(annotation);
    }

    public bool Undo()
    {
        if (!CanUndo) return false;
        undone.Push(committed[^1]);
        committed.RemoveAt(committed.Count - 1);
        return true;
    }

    public bool Redo()
    {
        if (!undone.TryPop(out var annotation)) return false;
        committed.Add(annotation);
        return true;
    }

    public void Clear()
    {
        committed.Clear();
        undone.Clear();
    }

    public void DiscardRedo() => undone.Clear();

    public IEnumerator<Annotation> GetEnumerator() => committed.GetEnumerator();
    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();
}
