using System.Windows.Media.Imaging;
using Slightshot.Core;

namespace Slightshot;

/// Keeps the real editor windows alive while native output dialogs own focus.
internal sealed class OverlayCoordinator(Settings settings, Func<CaptureAction, BitmapSource, bool> output, Action closed, Action<CapturedDisplay, RectD> record)
{
    private readonly CaptureSession session = new();
    private readonly List<OverlayWindow> windows = [];
    private bool closing;
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
            Register(window); window.Show();
            if (display == active) focus ??= window;
        }
        if (focus != null) TakeOver(focus);
        return true;
    }

    public bool PresentClipboardImage(BitmapSource bitmap)
    {
        if (!session.TryBegin()) return false;
        var area = System.Windows.SystemParameters.WorkArea;
        var source = EditorImageSource.Clipboard(bitmap, Math.Max(320, Math.Min(1000, area.Width - 100)), Math.Max(240, Math.Min(700, area.Height - 150)));
        var window = new OverlayWindow(source, settings, TakeOver, () => Dismiss(), Complete);
        Register(window); window.Show(); TakeOver(window);
        return true;
    }

    private void Register(OverlayWindow window)
    {
        windows.Add(window);
        window.Closing += (_, e) =>
        {
            if (closing) return;
            e.Cancel = true;
            if (!IsDelivering) window.Dispatcher.BeginInvoke(new Action(() => Dismiss()));
        };
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
        closing = true;
        try { foreach (var window in windows) window.Close(); windows.Clear(); }
        finally { closing = false; }
        closed();
    }
}
