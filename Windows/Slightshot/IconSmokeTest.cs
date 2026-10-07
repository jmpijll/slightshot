using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Slightshot;

internal static class IconSmokeTest
{
    internal static void Run(string directory, List<string> checks)
    {
        foreach (int scale in new[] { 1, 2 })
        {
            foreach (var icon in Enum.GetValues<ProductIcon>())
            {
                var visual = new DrawingVisual();
                using (var dc = visual.RenderOpen()) ProductIcons.Draw(icon, dc, Brushes.White);
                int side = (int)ProductIcons.Size * scale;
                var bitmap = new RenderTargetBitmap(side, side, 96 * scale, 96 * scale, PixelFormats.Pbgra32); bitmap.Render(visual);
                byte[] pixels = new byte[side * side * 4]; bitmap.CopyPixels(pixels, side * 4, 0);
                int ink = 0;
                for (int y = 0; y < side; y++) for (int x = 0; x < side; x++)
                {
                    byte alpha = pixels[(y * side + x) * 4 + 3]; if (alpha > 0) ink++;
                    if ((x == 0 || y == 0 || x == side - 1 || y == side - 1) && alpha != 0)
                        throw new InvalidOperationException($"Shared icon {icon} clips at {scale}×");
                }
                if (ink <= 20 * scale) throw new InvalidOperationException($"Shared icon {icon} has no readable artwork");
            }
            SaveBoard(directory, scale);
        }
        bool clicked = false;
        var record = new ToolbarButton(ProductIcon.Record, "Record selected area", () => clicked = true);
        if (record.Width != 30 || record.Height != 30 || AutomationProperties.GetName(record) != "Record selected area")
            throw new InvalidOperationException("Shared icon changed button size or accessibility");
        record.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Button.ClickEvent));
        if (!clicked) throw new InvalidOperationException("Shared icon changed the Record action");
        checks.Add($"{Enum.GetValues<ProductIcon>().Length} shared native WPF vectors render unclipped at 1×/2×; Record size/label/action retained. Production toolbar renderer produces normal, hover-style, selected and disabled fixtures. Source SHA-256: {ProductIcons.SourceHash}.");
    }

    private static void SaveBoard(string directory, int scale)
    {
        var visual = new DrawingVisual();
        var icons = Enum.GetValues<ProductIcon>();
        int width = 112 + icons.Length * 39 + 20;
        const int height = 280;
        using (var dc = visual.RenderOpen())
        {
            dc.DrawRectangle(Appearance.Brush("#17171A"), null, new Rect(0, 0, width, height));
            dc.DrawText(AnnotationRenderer.Text("Slightshot · shared native WPF icons", 15, Brushes.White), new Point(18, 16));
            string[] states = ["Normal", "Hover style", "Selected", "Disabled"];
            for (int row = 0; row < states.Length; row++)
            {
                double y = 75 + row * 46;
                dc.DrawText(AnnotationRenderer.Text(states[row], 11, Brushes.LightGray), new Point(18, y + 9));
                for (int column = 0; column < icons.Length; column++)
                {
                    var button = new ToolbarButton(icons[column], icons[column].ToString(), () => { }) { Selected = row == 2, IsEnabled = row != 3 };
                    double x = 112 + column * 39;
                    dc.PushTransform(new TranslateTransform(x, y)); button.DrawContent(dc, row == 1); dc.Pop();
                    if (row == 0) dc.DrawText(AnnotationRenderer.Text(icons[column].ToString(), 7, Brushes.LightGray), new Point(x, 58));
                }
            }
        }
        var bitmap = new RenderTargetBitmap(width * scale, height * scale, 96 * scale, 96 * scale, PixelFormats.Pbgra32); bitmap.Render(visual);
        using var stream = File.Create(Path.Combine(directory, $"icons-windows-{scale}x.png")); OutputService.Encode(bitmap, Slightshot.Core.ImageFormat.Png, 1).Save(stream);
    }
}
