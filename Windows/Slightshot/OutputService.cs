using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;
using Slightshot.Core;

namespace Slightshot;

internal sealed class OutputService(Settings settings, Action<string, string> notify,
    Func<SaveFileDialog, bool?>? showSaveDialog = null, Action<string>? presentError = null)
{
    public bool Perform(CaptureAction action, BitmapSource bitmap)
    {
        try
        {
            switch (action)
            {
                case CaptureAction.Copy: Copy(bitmap); break;
                case CaptureAction.Save: Save(bitmap); break;
                case CaptureAction.SaveAs:
                    if (!SaveAs(bitmap)) return false;
                    break;
                case CaptureAction.Print:
                    var print = new PrintDialog();
                    if (print.ShowDialog() != true) return false;
                    double scale = Math.Min(print.PrintableAreaWidth / bitmap.PixelWidth, print.PrintableAreaHeight / bitmap.PixelHeight);
                    var image = new Image { Source = bitmap, Width = bitmap.PixelWidth * scale, Height = bitmap.PixelHeight * scale, Stretch = Stretch.Fill };
                    image.Measure(new System.Windows.Size(image.Width, image.Height)); image.Arrange(new Rect(0, 0, image.Width, image.Height));
                    print.PrintVisual(image, "Slightshot screenshot"); break;
            }
            if (settings.PlaySound) System.Media.SystemSounds.Asterisk.Play();
            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Runtime.InteropServices.ExternalException or InvalidOperationException or ArgumentException or System.Printing.PrintSystemException)
        {
            string message = $"Slightshot could not complete this action.\n\n{ex.Message}";
            if (presentError != null) presentError(message);
            else MessageBox.Show(message, "Slightshot", MessageBoxButton.OK, MessageBoxImage.Warning);
            return false;
        }
    }

    private void Copy(BitmapSource bitmap)
    {
        var data = new DataObject();
        data.SetImage(bitmap);
        using var png = new MemoryStream(); Encode(bitmap, ImageFormat.Png, settings.JpegQuality).Save(png);
        data.SetData("PNG", new MemoryStream(png.ToArray()));
        Clipboard.SetDataObject(data, true);
        Feedback("Copied to clipboard", "");
    }

    private void Save(BitmapSource bitmap)
    {
        Directory.CreateDirectory(settings.SaveDirectory);
        string name = Name(bitmap), extension = settings.ImageFormat.Extension();
        for (int counter = 1; ; counter++)
        {
            string path = Path.Combine(settings.SaveDirectory, $"{name}{(counter == 1 ? "" : $" ({counter})")}.{extension}");
            FileStream stream;
            try { stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None); }
            catch (IOException) when (File.Exists(path)) { continue; }
            try { using (stream) Encode(bitmap, settings.ImageFormat, settings.JpegQuality).Save(stream); }
            catch { File.Delete(path); throw; }
            Saved(bitmap, path); return;
        }
    }

    private bool SaveAs(BitmapSource bitmap)
    {
        var dialog = new SaveFileDialog { Title = "Save screenshot", FileName = Name(bitmap), InitialDirectory = settings.SaveDirectory, DefaultExt = settings.ImageFormat.Extension(), Filter = "PNG image (*.png)|*.png|JPEG image (*.jpg)|*.jpg|TIFF image (*.tiff)|*.tiff", FilterIndex = (int)settings.ImageFormat + 1, AddExtension = true, OverwritePrompt = true };
        if ((showSaveDialog != null ? showSaveDialog(dialog) : dialog.ShowDialog()) != true) return false;
        var format = (ImageFormat)(dialog.FilterIndex - 1);
        // Encode before replacing an existing file so encoder failures cannot truncate it.
        using var encoded = new MemoryStream(); Encode(bitmap, format, settings.JpegQuality).Save(encoded);
        File.WriteAllBytes(dialog.FileName, encoded.ToArray()); Saved(bitmap, dialog.FileName); return true;
    }

    private void Saved(BitmapSource bitmap, string path)
    {
        if (settings.CopyAfterSave) Copy(bitmap);
        Feedback("Screenshot saved", path);
    }
    private void Feedback(string title, string text) { if (settings.ShowNotification) notify(title, text); }
    private string Name(BitmapSource bitmap) => OutputNaming.FileName(settings.FilenameTemplate, DateTimeOffset.Now, bitmap.PixelWidth, bitmap.PixelHeight);
    internal static BitmapEncoder Encode(BitmapSource image, ImageFormat format, double quality)
    {
        BitmapEncoder encoder = format switch { ImageFormat.Jpeg => new JpegBitmapEncoder { QualityLevel = (int)Math.Round(Math.Clamp(quality, 0.3, 1) * 100) }, ImageFormat.Tiff => new TiffBitmapEncoder { Compression = TiffCompressOption.Lzw }, _ => new PngBitmapEncoder() };
        encoder.Frames.Add(BitmapFrame.Create(image)); return encoder;
    }
}
