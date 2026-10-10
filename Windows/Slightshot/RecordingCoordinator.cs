using System.IO;
using System.Windows;
using Slightshot.Core;

namespace Slightshot;

internal sealed class RecordingCoordinator(Settings settings)
{
    private RecordingSession? session;
    private RecordingPanel? recordingPanel;
    private RecordingOutline? recordingOutline;
    private RecordingSaveWindow? saveWindow;
    private RecordingProgressWindow? progressWindow;
    private VideoEditorWindow? editorWindow;
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
            recordingPanel = new RecordingPanel(display, selection, () => { CloseRecordingControls(); current.Stop(); });
            recordingOutline = new RecordingOutline(display, selection);
            recordingOutline.Show();
            recordingPanel.Show();
            work = CompleteAsync(current);
        }
        catch (Exception error)
        {
            CloseRecordingControls();
            session?.Dispose(); session = null;
            MessageBox.Show($"Slightshot could not start recording.\n\n{error.Message}", "Slightshot", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private async Task CompleteAsync(RecordingSession current)
    {
        try
        {
            await current.RunAsync();
            CloseRecordingControls();
            if (!terminating)
            {
                var source = await VideoFrameSource.OpenAsync(current.SourcePath);
                if (terminating) { source.Dispose(); return; }
                try { editorWindow = new VideoEditorWindow(source, settings, annotations => ChooseDestinationAsync(current, annotations)); }
                catch { source.Dispose(); throw; }
                editorWindow.Show();
                await editorWindow.InitializeAsync();
                await editorWindow.Completion;
                editorWindow = null;
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { if (!terminating) MessageBox.Show($"Slightshot could not record the screen.\n\n{error.Message}", "Slightshot", MessageBoxButton.OK, MessageBoxImage.Warning); }
        finally
        {
            CloseRecordingControls();
            progressWindow?.Close(); progressWindow = null;
            exportCancellation?.Dispose(); exportCancellation = null;
            current.Dispose(); if (session == current) session = null;
        }
    }

    private async Task<bool> ChooseDestinationAsync(RecordingSession current, IReadOnlyList<TimedAnnotation> annotations)
    {
        if (terminating) return false;
        saveWindow = new RecordingSaveWindow(settings, current.Width, current.Height, null) { Owner = editorWindow };
        bool accepted = saveWindow.ShowDialog() == true;
        if (!accepted || terminating) { saveWindow = null; return false; }
        string proposed = saveWindow.Destination;
        RecordingQuality quality = saveWindow.Quality;
        saveWindow = null;
        settings.RecordingQuality = quality;
        exportCancellation = new CancellationTokenSource();
        progressWindow = new RecordingProgressWindow(() => exportCancellation?.Cancel()) { Owner = editorWindow };
        RecordingProgressWindow currentProgress = progressWindow;
        var progress = new Progress<double>(value => { if (progressWindow == currentProgress) currentProgress.Update(value); });
        progressWindow.Show();
        try
        {
            try { settings.Save(); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { System.Diagnostics.Debug.WriteLine("Could not persist recording quality: " + error.Message); }
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(proposed))!);
            await VideoAnnotationExport.SaveAsync(current.SourcePath, proposed, quality, current.Width, current.Height, annotations, exportCancellation.Token, progress);
            return true;
        }
        catch (OperationCanceledException) { return false; }
        catch (Exception error)
        {
            if (!terminating) MessageBox.Show(editorWindow, $"The recording could not be saved.\n\n{error.Message}\n\nYour recording and annotations are still available. Choose Save MP4 to try another location or quality.", "Save recording", MessageBoxButton.OK, MessageBoxImage.Warning);
            return false;
        }
        finally
        {
            progressWindow.Close(); progressWindow = null;
            exportCancellation.Dispose(); exportCancellation = null;
        }
    }

    internal async Task ShutdownAsync()
    {
        terminating = true; CloseRecordingControls(); saveWindow?.Close(); exportCancellation?.Cancel(); session?.Abort(); editorWindow?.CloseForShutdown();
        if (work != null) await work;
    }

    private void CloseRecordingControls()
    {
        recordingOutline?.Close(); recordingOutline = null;
        recordingPanel?.Close(); recordingPanel = null;
    }
}
