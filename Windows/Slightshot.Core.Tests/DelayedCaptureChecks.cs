using Slightshot.Core;

internal static class DelayedCaptureChecks
{
    internal static int Run()
    {
        int checks = 0, captures = 0, invalidated = 0, seconds = 0;
        double time = 100;
        bool busy = false, visible = false;
        var callbacks = new Queue<Action>();
        void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); checks++; }
        var controller = new DelayedCaptureController(() => time, (_, callback) =>
        {
            callbacks.Enqueue(callback); return () => invalidated++;
        }, () => busy, value => { seconds = value; visible = true; }, () => visible = false, () =>
        {
            Require(!visible, "countdown hides before screenshot sampling"); captures++; busy = true;
        });
        Require(controller.Start(), "idle timer starts");
        Require(seconds == 5 && captures == 0, "fixed delay does not sample at scheduling time");
        Action cancelled = callbacks.Dequeue(); controller.Cancel(); time = 110; cancelled();
        Require(captures == 0 && !controller.IsPending && !visible && invalidated == 1, "cancel rejects a queued stale callback");
        Require(controller.Start(), "capture starts after cancellation");
        Action replaced = callbacks.Dequeue(); time = 112;
        Require(controller.Start(), "repeated requests restart one timer"); replaced();
        Require(captures == 0 && callbacks.Count == 1, "replacement rejects previous callback");
        time = 116.999; callbacks.Dequeue()();
        Require(captures == 0 && seconds == 1, "timer cannot capture before full five seconds");
        time = 117; Action due = callbacks.Dequeue(); due(); due();
        Require(captures == 1 && !controller.IsPending && !visible, "deadline captures exactly once");
        Require(!controller.Start(), "editor or recording blocks scheduling");
        busy = false; Require(controller.Start(), "released editor permits scheduling");
        busy = true; time = 122; callbacks.Dequeue()();
        Require(captures == 1 && !controller.IsPending, "deadline rechecks editor or recording ownership");
        busy = false; Require(controller.Start(), "shutdown fixture schedules");
        Action terminated = callbacks.Dequeue(); controller.Cancel(); time = 200; terminated();
        Require(captures == 1 && !controller.IsPending, "quit or ordinary capture invalidates pending callback");
        return checks;
    }
}
