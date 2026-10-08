using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Slightshot.Core;

namespace Slightshot;

internal static class ScreenshotRetrySmokeTest
{
    public static void Run(string directory, List<string> checks)
    {
        var settings = new Settings { PlaySound = false, ShowNotification = false, CopyAfterSave = false };
        int dialogs = 0, errors = 0, closed = 0, recordings = 0;
        string saved = Path.Combine(Path.GetFullPath(directory), "retried-screenshot.png");
        var output = new OutputService(settings, (_, _) => { }, dialog =>
        {
            dialogs++;
            if (dialogs == 1) return false;
            dialog.FileName = dialogs == 2 ? Path.Combine(saved, "missing", "capture.png") : saved;
            return true;
        }, _ => errors++);
        OverlayCoordinator? coordinator = null;
        OverlayWindow? editor = null;
        var images = new List<byte[]>();
        coordinator = new OverlayCoordinator(settings, (action, bitmap) =>
        {
            Require(coordinator!.IsBusy && coordinator.IsDelivering, "capture stays busy during output");
            Require(coordinator.Windows.All(window => !window.IsVisible), "all overlays hide before native output");
            Require(!coordinator.Present([], null), "second capture is rejected during modal output");
            coordinator.Complete(editor!, action, bitmap);
            coordinator.Dismiss();
            Click(editor!, "Record selected area");
            Require(coordinator.Windows.Contains(editor!), "nested output, recording, and close retain original editor");
            images.Add(Bytes(bitmap));
            return output.Perform(action, bitmap);
        }, () => closed++, (_, _) => recordings++);
        var display = Fixture();
        Require(coordinator.Present([display, display], display), "synthetic capture starts");
        editor = coordinator.Windows[0];
        RectD selection = new(10, 10, 200, 120);
        editor.PrepareSmokeFixture(selection, [
            new(Tool.Blur, [new(25, 25), new(65, 65)], "#FF3B30", 3),
            new(Tool.Pixelate, [new(80, 25), new(120, 65)], "#FF3B30", 3)
        ]);
        // Drive the real text commit/export and Undo paths; no replacement editor model.
        Invoke(editor, "BeginText", new PointD(30, 80));
        var entry = Descendants((DependencyObject)editor.Content).OfType<TextBox>().Single();
        entry.Text = "Retry me";
        Invoke(editor, "Perform", CaptureAction.SaveAs);
        Require(coordinator.IsBusy && coordinator.Windows.Count == 2 && closed == 0, "cancel retains both frozen displays");
        Require(editor.IsVisible && ReferenceEquals(coordinator.Windows[0], editor), "cancel restores the same overlay");
        Require(!coordinator.Present([], null), "retained editor rejects second capture");
        Invoke(editor, "Perform", CaptureAction.SaveAs);
        Require(errors == 1 && closed == 0 && editor.IsVisible, "failed write restores editor after the error");
        Require(images[0].SequenceEqual(images[1]), "text, raster edits, and selected source survive cancellation and failure");
        Require(images[0][(4 * 200 + 4) * 4] == 0, "unedited pixels retain frozen source");
        Require(images[0][(30 * 200 + 30) * 4] is > 60 and < 195, "retained Blur changes real source pixels");
        Require(images[0][(35 * 200 + 85) * 4] is > 60 and < 195, "retained Pixelate changes real source pixels");
        Click(editor, "Undo  Ctrl+Z");
        Invoke(editor, "Perform", CaptureAction.SaveAs);
        Require(!images[1].SequenceEqual(images[2]), "Undo after failure removes committed text");
        Require(images[2][(30 * 200 + 30) * 4] == images[0][(30 * 200 + 30) * 4]
            && images[2][(35 * 200 + 85) * 4] == images[0][(35 * 200 + 85) * 4], "Undo leaves preceding raster effects intact");
        Require(File.Exists(saved), "successful retry writes an image");
        var decoded = new BitmapImage(new Uri(saved));
        Require(decoded.PixelWidth == 200 && decoded.PixelHeight == 120, "retry retains selected dimensions");
        Require(!coordinator.IsBusy && coordinator.Windows.Count == 0 && closed == 1 && recordings == 0 && dialogs == 3,
            "success releases editor once and duplicate input never reaches output or recording");

        Require(coordinator.Present([display], display), "new capture starts after success");
        var escapeEditor = coordinator.Windows[0];
        var source = PresentationSource.FromVisual(escapeEditor)!;
        escapeEditor.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, source, 0, Key.Escape) { RoutedEvent = Keyboard.PreviewKeyDownEvent });
        Require(!coordinator.IsBusy && closed == 2, "Escape closes the capture and releases the gate");
        checks.Add("Screenshot workflow: Save As cancellation, real failed write, retained two-display editor, text/Blur/Pixelate/Undo, nested input rejection, successful retry, and Escape passed");
        SettingsAfterFailedOutput(display, saved, checks);
    }

    private static void SettingsAfterFailedOutput(CapturedDisplay display, string existingImage, List<string> checks)
    {
        var app = (App)System.Windows.Application.Current;
        var overlaysField = typeof(App).GetField("overlays", BindingFlags.Instance | BindingFlags.NonPublic)!;
        var preferencesField = typeof(App).GetField("preferences", BindingFlags.Instance | BindingFlags.NonPublic)!;
        var showSettings = typeof(App).GetMethod("ShowSettings", BindingFlags.Instance | BindingFlags.NonPublic)!;
        var previousOverlays = overlaysField.GetValue(app);
        var previousPreferences = preferencesField.GetValue(app);
        var settings = new Settings { PlaySound = false, ShowNotification = false, CopyAfterSave = false,
            SaveDirectory = Path.Combine(existingImage, "screenshots") };
        // Supply an existing real Settings window so this fixture does not register
        // global hotkeys or create a tray icon when its window is later closed.
        var preferences = new SettingsWindow(settings);
        int errors = 0;
        var output = new OutputService(settings, (_, _) => { }, presentError: _ => errors++);
        OverlayCoordinator? coordinator = null;
        coordinator = new OverlayCoordinator(settings, (action, bitmap) =>
        {
            showSettings.Invoke(app, null);
            Require(!preferences.IsVisible && coordinator!.IsDelivering && coordinator.Windows.Count == 1,
                "Settings stays blocked while output owns modal focus");
            return output.Perform(action, bitmap);
        }, () => { }, (_, _) => { });
        overlaysField.SetValue(app, coordinator);
        preferencesField.SetValue(app, preferences);
        try
        {
            Require(coordinator.Present([display], display), "Settings retry capture starts");
            var editor = coordinator.Windows[0];
            editor.PrepareSmokeFixture(new RectD(10, 10, 200, 120), []);
            Invoke(editor, "Perform", CaptureAction.Save);
            Require(errors == 1 && editor.IsVisible && coordinator.IsBusy, "failed directory write restores editor before Settings");
            showSettings.Invoke(app, null);
            Require(preferences.IsVisible && !coordinator.IsBusy && coordinator.Windows.Count == 0,
                "Settings opens and dismisses an idle retained editor after output failure");
            var tabs = Descendants((DependencyObject)preferences.Content).OfType<TabControl>().Single();
            tabs.SelectedItem = tabs.Items.OfType<TabItem>().Single(tab => Equals(tab.Header, "Output"));
            preferences.UpdateLayout();
            Require(Descendants((DependencyObject)preferences.Content).OfType<Button>().Any(button =>
                Equals(button.Content, "Choose…") && button.IsVisible && button.IsEnabled),
                "save directory chooser is available after a failed write");
            checks.Add("Settings route: blocked during modal output; idle editor dismissed and Output folder chooser accessible after a real save-directory failure");
        }
        finally
        {
            preferences.Close(); coordinator.Dismiss();
            overlaysField.SetValue(app, previousOverlays);
            preferencesField.SetValue(app, previousPreferences);
        }
    }

    private static CapturedDisplay Fixture()
    {
        const int width = 320, height = 240;
        var pixels = new byte[width * height * 4];
        for (int y = 0; y < height; y++)
        for (int x = 0; x < width; x++)
        {
            int offset = (y * width + x) * 4;
            pixels[offset] = pixels[offset + 1] = pixels[offset + 2] = (byte)((x + y) % 2 == 0 ? 0 : 255);
            pixels[offset + 3] = 255;
        }
        var bitmap = BitmapSource.Create(width, height, 96, 96, PixelFormats.Pbgra32, null, pixels, width * 4);
        bitmap.Freeze();
        return new(bitmap, 0, 0, width, height, 1);
    }

    private static byte[] Bytes(BitmapSource bitmap)
    {
        var bytes = new byte[bitmap.PixelWidth * bitmap.PixelHeight * 4];
        bitmap.CopyPixels(bytes, bitmap.PixelWidth * 4, 0);
        return bytes;
    }

    private static void Invoke(OverlayWindow window, string method, object argument)
        => typeof(OverlayWindow).GetMethod(method, BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(window, [argument]);
    private static void Click(OverlayWindow window, string tooltip)
        => Descendants((DependencyObject)window.Content).OfType<Button>().Single(button => Equals(button.ToolTip, tooltip)).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    private static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
        {
            var child = VisualTreeHelper.GetChild(parent, i);
            yield return child;
            foreach (var descendant in Descendants(child)) yield return descendant;
        }
    }
    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException($"Screenshot retry smoke test failed: {message}");
    }
}
