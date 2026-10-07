namespace Slightshot.Core;

/// Owns the lifetime gate shared by capture, modal output, and explicit dismissal.
public sealed class CaptureSession
{
    public bool IsActive { get; private set; }
    public bool IsDelivering { get; private set; }
    public bool IsBusy => IsActive || IsDelivering;

    public bool TryBegin()
    {
        if (IsBusy) return false;
        IsActive = true;
        return true;
    }

    public bool Dismiss(Action close)
    {
        if (IsDelivering) return false;
        IsActive = false;
        close();
        return true;
    }

    public bool Perform(Func<bool> output, Action hide, Action restore, Action close)
    {
        if (!IsActive || IsDelivering) return false;
        IsDelivering = true;
        bool succeeded = false;
        try
        {
            hide();
            succeeded = output();
            return succeeded;
        }
        finally
        {
            IsDelivering = false;
            if (succeeded) Dismiss(close);
            else restore();
        }
    }
}
