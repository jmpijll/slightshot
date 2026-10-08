using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Slightshot.Core;

namespace Slightshot;

internal static class ClipboardEditorSmokeTest
{
    public static async Task RunAsync(string directory)
    {
        Directory.CreateDirectory(directory);
        var checks = new List<string>();
        System.Windows.Clipboard.Clear();
        Require(ClipboardImage.Read() == null, "empty clipboard returns no image");
        System.Windows.Clipboard.SetText("This is text, not an image");
        Require(ClipboardImage.Read() == null, "text clipboard returns no image");
        var files = new DataObject(); files.SetData(DataFormats.FileDrop, new[] { Path.Combine(directory, "clipboard-source.png") });
        System.Windows.Clipboard.SetDataObject(files, true);
        Require(ClipboardImage.Read() == null, "file drops are never opened as images");
        checks.Add("Empty, text and file-drop clipboards rejected without importing files");
        var fixture = Fixture();
        Save(fixture, Path.Combine(directory, "clipboard-source.png"));
        var data = new DataObject();
        using (var png = new MemoryStream())
        {
            OutputService.Encode(fixture, ImageFormat.Png, 1).Save(png);
            data.SetData("PNG", new MemoryStream(png.ToArray()));
        }
        data.SetImage(BitmapSource.Create(20, 10, 96, 96, PixelFormats.Bgra32, null, new byte[20 * 10 * 4], 20 * 4));
        System.Windows.Clipboard.SetDataObject(data, true);
        var decoded = ClipboardImage.Read()!;
        Require(decoded.PixelWidth == 2003 && decoded.PixelHeight == 1001, "direct PNG wins over the bitmap fallback and ignores physical DPI");
        Require(Alpha(decoded, 0, 0) == 0 && Alpha(decoded, 30, 30) == 128, "PNG read retains transparent and semitransparent pixels");
        checks.Add("Explicit clipboard PNG read: 2003 × 1001 at 192 DPI, including alpha 0 and 128");
        var settings = new Settings { NativeResolution = false, PlaySound = false, ShowNotification = false, CopyAfterSave = false };
        string exported = Path.GetFullPath(Path.Combine(directory, "clipboard-edited-export.png"));
        int dialogs = 0, errors = 0, closes = 0, attempts = 0;
        var output = new OutputService(settings, (_, _) => { }, dialog =>
        {
            dialogs++;
            if (dialogs == 1) return false;
            dialog.FileName = dialogs == 2 ? Path.Combine(exported, "missing", "capture.png") : exported;
            return true;
        }, _ => errors++);
        var app = (App)System.Windows.Application.Current;
        var field = typeof(App).GetField("overlays", BindingFlags.Instance | BindingFlags.NonPublic)!;
        var old = field.GetValue(app);
        OverlayCoordinator? coordinator = null;
        var deliveries = new List<byte[]>();
        coordinator = new OverlayCoordinator(settings, (action, bitmap) =>
        {
            attempts++;
            Require(coordinator!.IsBusy && coordinator.IsDelivering && coordinator.Windows.All(w => !w.IsVisible), "output owns the hidden editor");
            InvokeApp(app, "EditClipboard"); InvokeApp(app, "BeginCapture");
            Require(coordinator.Windows.Count == 1 && !coordinator.PresentClipboardImage(decoded), "busy gate rejects imports and captures");
            coordinator.Windows[0].Close();
            Require(coordinator.Windows.Count == 1, "native close is ignored during modal output");
            deliveries.Add(Bytes(bitmap));
            return output.Perform(action, bitmap);
        }, () => closes++, (_, _) => throw new InvalidOperationException("Clipboard images must not record"));
        field.SetValue(app, coordinator);
        try
        {
            // Exercise the actual tray action route, clipboard decode and native window.
            InvokeApp(app, "EditClipboard");
            var editor = coordinator.Windows.Single();
            await Task.Delay(250); editor.UpdateLayout();
            Require(editor.Title == "Edit Image from Clipboard" && editor.WindowStyle != WindowStyle.None && editor.IsVisible, "clipboard opens a titled native editor");
            Require(!Buttons(editor).Any(b => Equals(b.ToolTip, "Record selected area")), "record action absent for image imports");
            var source = EditorImageSource.Clipboard(decoded, Math.Max(320, Math.Min(1000, SystemParameters.WorkArea.Width - 100)), Math.Max(240, Math.Min(700, SystemParameters.WorkArea.Height - 150)));
            editor.PrepareSmokeFixture(source.Bounds, [
                new(Tool.Arrow, [new(120 / source.Scale, 200 / source.Scale), new(800 / source.Scale, 450 / source.Scale)], "#FF3B30", 3),
                new(Tool.Step, [new(1150 / source.Scale, 450 / source.Scale)], "#FF3B30", 3, StepNumber: 1)
            ]);
            Click(editor, "100%"); await Task.Delay(100); Click(editor, "Fit"); await Task.Delay(100);
            CaptureWindow(editor, Path.Combine(directory, "clipboard-editor-window.png"));
            checks.Add("Actual native WPF window: image selection, annotation fixture, Fit/100% viewing and hidden recording action; desktop screenshot saved");
            Perform(editor, CaptureAction.SaveAs);
            Require(editor.IsVisible && coordinator.IsBusy && ReferenceEquals(coordinator.Windows.Single(), editor), "cancel restores the same editable image");
            Perform(editor, CaptureAction.SaveAs);
            Require(editor.IsVisible && errors == 1 && coordinator.IsBusy, "real failed file write restores editor for retry");
            Require(deliveries[0].SequenceEqual(deliveries[1]), "annotations survive cancellation and output failure");
            Perform(editor, CaptureAction.SaveAs);
            Require(!coordinator.IsBusy && closes == 1 && attempts == 3, "successful retry releases ownership exactly once");
            var saved = new BitmapImage(new Uri(exported));
            Require(saved.PixelWidth == 2003 && saved.PixelHeight == 1001, "fit and disabled native screenshot setting never downsample imports");
            Require(Alpha(saved, 0, 0) == 0 && Alpha(saved, 30, 30) == 128, "PNG export retains unchanged alpha");
            checks.Add("Real OutputService: cancelled Save As, failed write, retained edits, successful PNG export at original resolution and alpha, busy input rejection");
            InvokeApp(app, "EditClipboard");
            coordinator.Windows.Single().Close();
            await Task.Delay(50);
            Require(!coordinator.IsBusy && closes == 2, "native window close releases ownership");
            checks.Add("Native close releases the capture/editor gate and permits the next import");
        }
        finally { coordinator.Dismiss(); field.SetValue(app, old); }
        System.Windows.Clipboard.SetImage(fixture);
        Require(ClipboardImage.Read()?.PixelWidth == 2003, "native bitmap fallback works");
        checks.Add("Native Bitmap clipboard fallback read passed");
        File.WriteAllText(Path.Combine(directory, "clipboard-validation.json"), JsonSerializer.Serialize(new
        {
            source = "Actual WPF app and clipboard smoke run on Windows; synthetic transparent image and annotation fixture",
            platform = Environment.OSVersion.ToString(), checks
        }, new JsonSerializerOptions { WriteIndented = true }));
    }

    private static BitmapSource Fixture()
    {
        const int width = 2003, height = 1001;
        var pixels = new byte[width * height * 4];
        for (int y = 10; y < height - 10; y++)
        for (int x = 10; x < width - 10; x++)
        {
            int offset = (y * width + x) * 4;
            pixels[offset] = 128; pixels[offset + 1] = 70; pixels[offset + 2] = 20; pixels[offset + 3] = 128;
        }
        var bitmap = BitmapSource.Create(width, height, 192, 192, PixelFormats.Pbgra32, null, pixels, width * 4); bitmap.Freeze(); return bitmap;
    }
    private static void CaptureWindow(Window window, string path)
    {
        Require(GetWindowRect(new WindowInteropHelper(window).Handle, out var rect), "native screenshot window bounds");
        using var bitmap = new System.Drawing.Bitmap(rect.Right - rect.Left, rect.Bottom - rect.Top);
        using var graphics = System.Drawing.Graphics.FromImage(bitmap);
        graphics.CopyFromScreen(rect.Left, rect.Top, 0, 0, bitmap.Size);
        bitmap.Save(path, System.Drawing.Imaging.ImageFormat.Png);
    }
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetWindowRect(IntPtr handle, out NativeMethods.NativeRect rect);
    private static void Save(BitmapSource bitmap, string path) { using var stream = File.Create(path); OutputService.Encode(bitmap, ImageFormat.Png, 1).Save(stream); }
    private static byte[] Bytes(BitmapSource bitmap) { var converted = new FormatConvertedBitmap(bitmap, PixelFormats.Pbgra32, null, 0); var bytes = new byte[bitmap.PixelWidth * bitmap.PixelHeight * 4]; converted.CopyPixels(bytes, bitmap.PixelWidth * 4, 0); return bytes; }
    private static int Alpha(BitmapSource bitmap, int x, int y) { var converted = new FormatConvertedBitmap(bitmap, PixelFormats.Bgra32, null, 0); byte[] pixel = new byte[4]; converted.CopyPixels(new Int32Rect(x, y, 1, 1), pixel, 4, 0); return pixel[3]; }
    private static void InvokeApp(App app, string method) => typeof(App).GetMethod(method, BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(app, null);
    private static void Perform(OverlayWindow window, CaptureAction action) => typeof(OverlayWindow).GetMethod("Perform", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(window, [action]);
    private static void Click(OverlayWindow window, string label) => Buttons(window).Single(b => Equals(b.Content, label)).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    private static IEnumerable<Button> Buttons(OverlayWindow window) => Descendants((DependencyObject)window.Content).OfType<Button>();
    private static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
        {
            var child = VisualTreeHelper.GetChild(parent, i); yield return child;
            foreach (var descendant in Descendants(child)) yield return descendant;
        }
    }
    private static void Require(bool condition, string check) { if (!condition) throw new InvalidOperationException($"Clipboard editor smoke test failed: {check}"); }
}
