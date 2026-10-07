using System.IO;
using System.Windows;
using Slightshot.Core;

namespace Slightshot;

internal sealed class RecordingCoordinator(Settings settings)
{
    private RecordingSession? session;
    private RecordingPanel? recordingPanel;
    private RecordingSaveWindow? saveWindow;
    private RecordingProgressWindow? progressWindow;
    private CancellationTokenSource? exportCancellation;
    private Task? work;
    private bool terminating;
    internal bool IsBusy => session != null;

    internal void Begin(CapturedDisplay display, RectD selection)
    {
        if (IsBusy || terminating) return;
        try
        {
            if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041)) throw new NotSupportedException("Screen recording requires Windows 10 version 2004 or later so Slightshot can exclude its controls from the video.");
            session = RecordingSession.Create(display, selection, settings.CaptureCursor, settings.NativeResolution);
            RecordingSession current = session;
            current.Started += () => Application.Current.Dispatcher.InvokeAsync(() => { if (session == current && !terminating) recordingPanel?.Started(() => current.Duration); });
            recordingPanel = new RecordingPanel(display, selection, () => { recordingPanel?.Close(); recordingPanel = null; current.Stop(); });
            recordingPanel.Show();
            work = CompleteAsync(current);
        }
        catch (Exception error)
        {
            recordingPanel?.Close(); recordingPanel = null;
            session?.Dispose(); session = null;
            MessageBox.Show($"Slightshot could not start recording.\n\n{error.Message}", "Slightshot", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private async Task CompleteAsync(RecordingSession current)
    {
        try
        {
            await current.RunAsync();
            recordingPanel?.Close(); recordingPanel = null;
            if (!terminating) await ChooseDestinationAsync(current);
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { if (!terminating) MessageBox.Show($"Slightshot could not record the screen.\n\n{error.Message}", "Slightshot", MessageBoxButton.OK, MessageBoxImage.Warning); }
        finally
        {
            recordingPanel?.Close(); recordingPanel = null;
            progressWindow?.Close(); progressWindow = null;
            exportCancellation?.Dispose(); exportCancellation = null;
            current.Dispose(); if (session == current) session = null;
        }
    }

    private async Task ChooseDestinationAsync(RecordingSession current)
    {
        string? proposed = null;
        while (!terminating)
        {
            saveWindow = new RecordingSaveWindow(settings, current.Width, current.Height, proposed);
            bool accepted = saveWindow.ShowDialog() == true;
            if (terminating) return;
            if (!accepted)
            {
                saveWindow = null;
                if (MessageBox.Show("Keep this recording and choose a location, or discard it?", "Keep this recording?", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.No) return;
                continue;
            }
            proposed = saveWindow.Destination; RecordingQuality quality = saveWindow.Quality; saveWindow = null;
            settings.RecordingQuality = quality;
            exportCancellation = new CancellationTokenSource();
            progressWindow = new RecordingProgressWindow(() => exportCancellation?.Cancel());
            RecordingProgressWindow currentProgress = progressWindow;
            var progress = new Progress<double>(value => { if (progressWindow == currentProgress) currentProgress.Update(value); });
            progressWindow.Show();
            try
            {
                try { settings.Save(); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { System.Diagnostics.Debug.WriteLine("Could not persist recording quality: " + error.Message); }
                Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(proposed))!);
                await RecordingExport.SaveAsync(current.SourcePath, proposed, quality, current.Width, current.Height, exportCancellation.Token, progress);
                return;
            }
            catch (OperationCanceledException) { if (terminating) return; }
            catch (Exception error)
            {
                if (terminating) return;
                if (MessageBox.Show($"The recording could not be saved.\n\n{error.Message}\n\nYour recording is still available. Try another location or quality?", "Save recording", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
            }
            finally { progressWindow.Close(); progressWindow = null; exportCancellation.Dispose(); exportCancellation = null; }
        }
    }

    internal async Task ShutdownAsync()
    {
        terminating = true; saveWindow?.Close(); exportCancellation?.Cancel(); session?.Abort();
        if (work != null) await work;
    }
}
