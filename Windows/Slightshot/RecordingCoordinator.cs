using System.IO;
using System.Windows;
using System.Windows.Interop;
using Slightshot.Core;

namespace Slightshot;

internal sealed class RecordingCoordinator(Settings settings)
{
    private const string UnsavedReason = "An unsaved recording is open in Slightshot.";
    private RecordingSession? session;
    private RecordingDirectory? files;
    private RecordingPanel? recordingPanel;
    private RecordingOutline? recordingOutline;
    private RecordingSaveWindow? saveWindow;
    private RecordingProgressWindow? progressWindow;
    private VideoEditorWindow? editorWindow;
    private CancellationTokenSource? exportCancellation;
    private Task? work;
    private bool terminating;
    internal bool IsBusy => files != null;

    internal void Begin(CapturedDisplay display, RectD selection)
    {
        if (IsBusy || terminating) return;
        try
        {
            if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041)) throw new NotSupportedException("Screen recording requires Windows 10 version 2004 or later so Slightshot can exclude its controls from the video.");
            session = RecordingSession.Create(display, selection, settings.CaptureCursor, settings.NativeResolution);
            RecordingSession current = session;
            files = current.Files;
            current.Started += () => Application.Current.Dispatcher.InvokeAsync(() => { if (session == current && !terminating) recordingPanel?.Started(() => current.Duration); });
            recordingPanel = new RecordingPanel(display, selection, () => { CloseRecordingControls(); current.Stop(); });
            recordingOutline = new RecordingOutline(display, selection);
            recordingOutline.Show();
            recordingPanel.Show();
            BlockShutdown(recordingPanel);
            work = CompleteAsync(current);
        }
        catch (Exception error)
        {
            CloseRecordingControls();
            session?.Dispose(); session = null; files = null;
            MessageBox.Show($"Slightshot could not start recording.\n\n{error.Message}", "Slightshot", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    // Startup: delete leftovers from crashed sessions and offer recordings kept
    // by an ended Windows session.
    internal void Recover(Func<RecordingDirectory, bool>? reopen = null)
    {
        var kept = RecordingDirectory.Sweep();
        if (kept.Count > 0) work = RecoverAsync(kept, reopen ?? AskToReopen);
    }

    // Windows may end the session despite the cancel (critical shutdown, or
    // "Shut down anyway"), so the source is kept for the next launch first.
    internal bool KeepForSessionEnd()
    {
        if (files == null || terminating) return false;
        try { files.Keep(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { System.Diagnostics.Debug.WriteLine("Could not keep recording for next launch: " + error.Message); }
        // A stopped recording finalizes its MP4, so a forced end leaves it playable.
        if (recordingPanel != null) { CloseRecordingControls(); session?.Stop(); }
        return true;
    }

    private async Task CompleteAsync(RecordingSession current)
    {
        try
        {
            await current.RunAsync();
            CloseRecordingControls();
            if (!terminating) await EditAsync(current.Files);
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { if (!terminating) MessageBox.Show($"Slightshot could not record the screen.\n\n{error.Message}", "Slightshot", MessageBoxButton.OK, MessageBoxImage.Warning); }
        finally
        {
            CloseRecordingControls();
            current.Dispose(); if (session == current) session = null;
            Release();
        }
    }

    private async Task RecoverAsync(List<RecordingDirectory> kept, Func<RecordingDirectory, bool> reopen)
    {
        foreach (var recording in kept)
        {
            // Quitting before the user answers keeps the source for the next
            // launch; its owner lock ends with the process.
            if (terminating) continue;
            files = recording;
            bool keep = false;
            try
            {
                bool open = reopen(recording);
                keep = terminating;
                if (open && !keep) await EditAsync(recording);
            }
            catch (OperationCanceledException) { }
            catch (Exception error) { if (!terminating) MessageBox.Show($"Slightshot could not reopen the unsaved recording.\n\n{error.Message}", "Slightshot", MessageBoxButton.OK, MessageBoxImage.Warning); }
            finally
            {
                if (!keep) recording.Dispose();
                Release();
            }
        }
    }

    private static bool AskToReopen(RecordingDirectory recording) => MessageBox.Show(
        $"Slightshot kept an unsaved recording when Windows ended your session on {recording.KeptAt:g}.\n\nOpen it in the editor now? Choose No to delete it.",
        "Slightshot", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes;

    private async Task EditAsync(RecordingDirectory recording)
    {
        var source = await VideoFrameSource.OpenAsync(recording.SourcePath);
        if (terminating) { source.Dispose(); return; }
        try { editorWindow = new VideoEditorWindow(source, settings, annotations => ChooseDestinationAsync(recording.SourcePath, source.Width, source.Height, annotations)); }
        catch { source.Dispose(); throw; }
        editorWindow.Show();
        BlockShutdown(editorWindow);
        await editorWindow.InitializeAsync();
        await editorWindow.Completion;
        editorWindow = null;
    }

    private async Task<bool> ChooseDestinationAsync(string sourcePath, int width, int height, IReadOnlyList<TimedAnnotation> annotations)
    {
        if (terminating) return false;
        saveWindow = new RecordingSaveWindow(settings, width, height, null) { Owner = editorWindow };
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
            await VideoAnnotationExport.SaveAsync(sourcePath, proposed, quality, width, height, annotations, exportCancellation.Token, progress);
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

    // The reason is shown in Windows' sign-out screen while this window is
    // open; it is released with the window.
    private static void BlockShutdown(Window window)
    {
        if (!RecordingNative.ShutdownBlockReasonCreate(new WindowInteropHelper(window).Handle, UnsavedReason))
            System.Diagnostics.Debug.WriteLine("Could not register shutdown block reason.");
    }

    private void Release()
    {
        progressWindow?.Close(); progressWindow = null;
        exportCancellation?.Dispose(); exportCancellation = null;
        files = null;
    }

    private void CloseRecordingControls()
    {
        recordingOutline?.Close(); recordingOutline = null;
        recordingPanel?.Close(); recordingPanel = null;
    }
}
