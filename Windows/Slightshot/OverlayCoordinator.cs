using System.Windows.Media.Imaging;
using Slightshot.Core;

namespace Slightshot;

/// Keeps the real editor windows alive while native output dialogs own focus.
internal sealed class OverlayCoordinator(Settings settings, Func<CaptureAction, BitmapSource, bool> output, Action closed, Action<CapturedDisplay, RectD> record)
{
    private readonly CaptureSession session = new();
    private readonly List<OverlayWindow> windows = [];
    public IReadOnlyList<OverlayWindow> Windows => windows;
    public bool IsBusy => session.IsBusy;
    public bool IsDelivering => session.IsDelivering;

    public bool Present(IEnumerable<CapturedDisplay> displays, CapturedDisplay? active)
    {
        if (!session.TryBegin()) return false;
        OverlayWindow? focus = null;
        foreach (var display in displays)
        {
            var window = new OverlayWindow(display, settings, display == active, TakeOver, () => Dismiss(), Complete, StartRecording);
            windows.Add(window); window.Show();
            if (display == active) focus ??= window;
        }
        if (focus != null) TakeOver(focus);
        return true;
    }

    public void TakeOver(OverlayWindow window)
    {
        if (IsDelivering || !windows.Contains(window)) return;
        foreach (var other in windows.Where(other => other != window)) other.Relinquish();
        window.Activate(); window.Focus();
    }

    public void Complete(OverlayWindow window, CaptureAction action, BitmapSource bitmap)
    {
        if (!windows.Contains(window)) return;
        session.Perform(() => output(action, bitmap),
            () => { foreach (var overlay in windows) overlay.Hide(); },
            () =>
            {
                foreach (var overlay in windows) overlay.Show();
                TakeOver(window);
            }, Close);
    }

    private void StartRecording(CapturedDisplay display, RectD selection)
    {
        if (!IsDelivering && session.IsActive) record(display, selection);
    }

    public bool Dismiss() => session.Dismiss(Close);

    private void Close()
    {
        foreach (var window in windows) window.Close();
        windows.Clear();
        closed();
    }
}
