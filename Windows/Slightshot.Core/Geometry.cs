namespace Slightshot.Core;

public readonly record struct PointD(double X, double Y)
{
    public PointD Clamp(RectD bounds) => new(Math.Clamp(X, bounds.Left, bounds.Right), Math.Clamp(Y, bounds.Top, bounds.Bottom));
}

public readonly record struct RectD(double X, double Y, double Width, double Height)
{
    public double Left => X;
    public double Top => Y;
    public double Right => X + Width;
    public double Bottom => Y + Height;
    public double MidX => X + Width / 2;
    public double MidY => Y + Height / 2;
    public bool Contains(PointD p) => p.X >= Left && p.X <= Right && p.Y >= Top && p.Y <= Bottom;
    public static RectD Between(PointD a, PointD b) => new(Math.Min(a.X, b.X), Math.Min(a.Y, b.Y), Math.Abs(b.X - a.X), Math.Abs(b.Y - a.Y));
    public RectD Clamp(RectD bounds) => Between(new PointD(Left, Top).Clamp(bounds), new PointD(Right, Bottom).Clamp(bounds));
    public RectD MoveTo(PointD origin, RectD bounds) => new(Math.Clamp(origin.X, bounds.Left, Math.Max(bounds.Left, bounds.Right - Width)), Math.Clamp(origin.Y, bounds.Top, Math.Max(bounds.Top, bounds.Bottom - Height)), Width, Height);
    public RectD ToPixels(double scaleX, double scaleY, int pixelWidth, int pixelHeight)
    {
        int left = Math.Clamp((int)Math.Floor(Left * scaleX), 0, pixelWidth - 1);
        int top = Math.Clamp((int)Math.Floor(Top * scaleY), 0, pixelHeight - 1);
        int right = Math.Clamp((int)Math.Ceiling(Right * scaleX), left + 1, pixelWidth);
        int bottom = Math.Clamp((int)Math.Ceiling(Bottom * scaleY), top + 1, pixelHeight);
        return new(left, top, right - left, bottom - top);
    }
}

public enum SelectionHandle { TopLeft, Top, TopRight, Right, BottomRight, Bottom, BottomLeft, Left }

public static class SelectionGeometry
{
    public const double DrawSize = 7;
    public const double HitSize = 16;
    private static readonly SelectionHandle[] HitOrder = [SelectionHandle.TopLeft, SelectionHandle.TopRight, SelectionHandle.BottomLeft, SelectionHandle.BottomRight, SelectionHandle.Top, SelectionHandle.Bottom, SelectionHandle.Left, SelectionHandle.Right];

    public static PointD Anchor(this SelectionHandle handle, RectD r) => handle switch
    {
        SelectionHandle.TopLeft => new(r.Left, r.Top), SelectionHandle.Top => new(r.MidX, r.Top),
        SelectionHandle.TopRight => new(r.Right, r.Top), SelectionHandle.Right => new(r.Right, r.MidY),
        SelectionHandle.BottomRight => new(r.Right, r.Bottom), SelectionHandle.Bottom => new(r.MidX, r.Bottom),
        SelectionHandle.BottomLeft => new(r.Left, r.Bottom), _ => new(r.Left, r.MidY)
    };
    public static SelectionHandle? Hit(PointD p, RectD r)
    {
        foreach (var handle in HitOrder)
        {
            var anchor = handle.Anchor(r);
            if (Math.Abs(p.X - anchor.X) <= HitSize / 2 && Math.Abs(p.Y - anchor.Y) <= HitSize / 2) return handle;
        }
        return null;
    }
    public static RectD Resize(this SelectionHandle handle, RectD r, PointD p)
    {
        double left = r.Left, right = r.Right, top = r.Top, bottom = r.Bottom;
        if (handle is SelectionHandle.TopLeft or SelectionHandle.Left or SelectionHandle.BottomLeft) left = p.X;
        if (handle is SelectionHandle.TopRight or SelectionHandle.Right or SelectionHandle.BottomRight) right = p.X;
        if (handle is SelectionHandle.TopLeft or SelectionHandle.Top or SelectionHandle.TopRight) top = p.Y;
        if (handle is SelectionHandle.BottomLeft or SelectionHandle.Bottom or SelectionHandle.BottomRight) bottom = p.Y;
        return RectD.Between(new(left, top), new(right, bottom));
    }
    public static RectD Square(PointD start, PointD end, RectD bounds)
    {
        double side = Math.Max(Math.Abs(end.X - start.X), Math.Abs(end.Y - start.Y));
        return RectD.Between(start, new(start.X + (end.X < start.X ? -side : side), start.Y + (end.Y < start.Y ? -side : side))).Clamp(bounds);
    }
    public static PointD AxisLocked(PointD start, PointD end)
    {
        double dx = end.X - start.X, dy = end.Y - start.Y;
        double angle = Math.Round(Math.Atan2(dy, dx) / (Math.PI / 4)) * (Math.PI / 4);
        double length = Math.Sqrt(dx * dx + dy * dy);
        return new(start.X + Math.Cos(angle) * length, start.Y + Math.Sin(angle) * length);
    }
}
