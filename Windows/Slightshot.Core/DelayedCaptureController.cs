namespace Slightshot.Core;

// Owned by the UI thread. Tokens reject callbacks already queued before Cancel,
// replacement or shutdown. The monotonic clock prevents an early timer firing.
public sealed class DelayedCaptureController(Func<double> now, Func<double, Action, Action> schedule,
    Func<bool> isBusy, Action<int> show, Action hide, Action capture)
{
    private Action? cancellation;
    private long generation;
    private double? deadline;
    public bool IsPending => deadline.HasValue;

    public bool Start()
    {
        if (isBusy()) return false;
        Cancel();
        deadline = now() + 5;
        show(5);
        Arm(generation);
        return true;
    }

    public void Cancel()
    {
        generation++;
        deadline = null;
        cancellation?.Invoke();
        cancellation = null;
        hide();
    }

    private void Arm(long token) => cancellation = schedule(0.1, () => Tick(token));
    private void Tick(long token)
    {
        if (token != generation || !deadline.HasValue) return;
        cancellation = null;
        double remaining = deadline.Value - now();
        if (remaining > 0)
        {
            show((int)Math.Ceiling(remaining));
            Arm(token);
        }
        else
        {
            Cancel();
            if (!isBusy()) capture();
        }
    }
}
