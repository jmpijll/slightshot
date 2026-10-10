using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Slightshot.Core;

namespace Slightshot;

internal static class VideoAnnotationRenderer
{
    // Shared by native preview and export. Compositing order, glyphs and effect
    // regions are the same as the screenshot editor; only time filters marks.
    internal static BitmapSource Render(BitmapSource frame, TimeSpan position, IReadOnlyList<TimedAnnotation> annotations)
    {
        var visible = annotations.Where(item => item.IsVisible(position)).Select(item => item.Annotation).ToArray();
        if (visible.Length == 0) return frame;
        var source = new EditorImageSource(frame, 1);
        return AnnotationRenderer.Flatten(source, source.Bounds, visible);
    }
}

// WPF's raster compositor needs an STA dispatcher. Export owns a separate one,
// so full-size blur frames do not block editor controls or cancellation input.
internal sealed class VideoRenderWorker : IDisposable
{
    private readonly Thread thread;
    private readonly TaskCompletionSource<Dispatcher> ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal VideoRenderWorker()
    {
        thread = new Thread(() => { ready.SetResult(Dispatcher.CurrentDispatcher); Dispatcher.Run(); }) { IsBackground = true, Name = "Slightshot video compositor" };
        thread.SetApartmentState(ApartmentState.STA); thread.Start();
    }
    internal async Task<BitmapSource> RenderAsync(BitmapSource frame, TimeSpan position, IReadOnlyList<TimedAnnotation> annotations, CancellationToken cancellation)
    {
        var dispatcher = await ready.Task.ConfigureAwait(false);
        return await dispatcher.InvokeAsync(() => VideoAnnotationRenderer.Render(frame, position, annotations), DispatcherPriority.Background, cancellation).Task.ConfigureAwait(false);
    }
    public void Dispose()
    {
        // Cancellation or a failed destination can happen before the render
        // thread starts. Wait for its dispatcher before requesting shutdown;
        // joining first would strand a freshly started Dispatcher.Run loop.
        ready.Task.GetAwaiter().GetResult().BeginInvokeShutdown(DispatcherPriority.Background);
        thread.Join();
    }
}
