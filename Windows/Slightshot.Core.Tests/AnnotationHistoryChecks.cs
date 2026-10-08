using Slightshot.Core;

internal static class AnnotationHistoryChecks
{
    internal static int Run()
    {
        int checks = 0;
        void Require(bool condition, string message)
        {
            if (!condition) throw new InvalidOperationException($"Annotation history: {message}");
            checks++;
        }

        var history = new AnnotationHistory();
        Require(!history.Undo() && !history.Redo(), "empty undo and redo are harmless");
        Require(!history.CanUndo && !history.CanRedo, "empty history has no available commands");
        Annotation[] original = [
            new(Tool.Pen, [new(10, 20), new(30, 40)], "#FF3B30", 3),
            new(Tool.Blur, [new(12, 22), new(28, 38)], "#FF3B30", 3),
            new(Tool.Step, [new(40, 50)], "#0A84FF", 3, StepNumber: 1),
            new(Tool.Pixelate, [new(32, 42), new(48, 58)], "#FF3B30", 3),
            new(Tool.Text, [new(60, 70)], "#FFFFFF", 3, Text: "Restore me"),
            new(Tool.Step, [new(80, 90)], "#FFCC00", 3, StepNumber: 2)
        ];
        history.AddRange(original);
        Require(history.CanUndo && !history.CanRedo, "committing annotations enables only undo");
        Require(Annotation.NextStepNumber(history) == 3, "committed steps determine the next stamp");
        Require(history.Undo() && Annotation.NextStepNumber(history) == 2, "undo returns the next stamp to the removed number");
        Require(history.Undo() && history.Undo(), "multiple undo removes text and the later raster effect");
        Require(history.SequenceEqual(original.Take(3)), "undo retains the ordered earlier vector, effect and step");
        Require(history.Redo() && ReferenceEquals(history[^1], original[3]), "first redo restores the original later effect");
        Require(history.Redo() && ReferenceEquals(history[^1], original[4]), "next redo restores original text and style");
        Require(history.Redo() && ReferenceEquals(history[^1], original[5]), "last redo restores the original numbered step");
        Require(history.SequenceEqual(original) && Annotation.NextStepNumber(history) == 3, "redo restores composition order and step numbering");
        Require(!history.Redo() && history.Count == 6 && !history.CanRedo, "exhausted redo cannot duplicate the last annotation");
        for (int cycle = 0; cycle < 3; cycle++)
        {
            for (int i = 0; i < original.Length; i++) Require(history.Undo(), $"cycle {cycle} can undo annotation {i}");
            Require(!history.CanUndo && history.CanRedo && Annotation.NextStepNumber(history) == 1, "undoing all marks resets step numbering");
            for (int i = 0; i < original.Length; i++) Require(history.Redo(), $"cycle {cycle} can redo annotation {i}");
            Require(history.SequenceEqual(original), "repeated cycles restore exact objects in original order");
        }
        history.Undo();
        var replacement = new Annotation(Tool.Step, [new(100, 110)], "#34C759", 8, StepNumber: Annotation.NextStepNumber(history));
        history.Add(replacement);
        Require(!history.CanRedo && !history.Redo() && ReferenceEquals(history[^1], replacement), "a new annotation discards the abandoned redo branch");
        Require(replacement.StepNumber == 2 && Annotation.NextStepNumber(history) == 3, "a new step after undo reuses the removed number");
        history.Undo();
        history.Clear();
        Require(history.Count == 0 && !history.CanUndo && !history.CanRedo && !history.Redo(), "a new selection clears committed and redo annotations");
        history.Add(original[0]);
        Require(history.Count == 1 && !history.CanRedo && Annotation.NextStepNumber(history) == 1, "new selection history starts independently");
        history.Add(original[1]);
        history.Undo();
        history.DiscardRedo();
        Require(history.Count == 1 && ReferenceEquals(history[0], original[0]) && !history.Redo(), "selecting the full display drops redo while retaining existing marks");
        return checks;
    }
}
