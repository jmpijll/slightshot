using System.Windows.Input;
using System.Windows.Interop;

namespace Slightshot;

public sealed record HotKey(uint Key, uint Modifiers)
{
    public bool IsEmpty => Key == 0;
    public bool IsValid => IsEmpty || (Modifiers & 0x0f) != 0 && Key is > 0 and <= 0xff && (Modifiers & ~0x0fu) == 0;
    public override string ToString()
    {
        if (IsEmpty) return "None";
        string key = KeyInterop.KeyFromVirtualKey((int)Key).ToString();
        if (key.Length == 2 && key[0] == 'D') key = key[1..];
        return ((Modifiers & 2) != 0 ? "Ctrl+" : "") + ((Modifiers & 4) != 0 ? "Shift+" : "") + ((Modifiers & 1) != 0 ? "Alt+" : "") + ((Modifiers & 8) != 0 ? "Win+" : "") + key;
    }
    public static HotKey? FromKey(Key key, ModifierKeys modifiers)
    {
        if (key == System.Windows.Input.Key.Escape) return new(0, 0);
        if (key is System.Windows.Input.Key.LeftCtrl or System.Windows.Input.Key.RightCtrl or System.Windows.Input.Key.LeftShift or System.Windows.Input.Key.RightShift or System.Windows.Input.Key.LeftAlt or System.Windows.Input.Key.RightAlt or System.Windows.Input.Key.LWin or System.Windows.Input.Key.RWin or System.Windows.Input.Key.System) return null;
        uint mask = (modifiers.HasFlag(ModifierKeys.Control) ? 2u : 0) | (modifiers.HasFlag(ModifierKeys.Shift) ? 4u : 0) | (modifiers.HasFlag(ModifierKeys.Alt) ? 1u : 0) | (modifiers.HasFlag(ModifierKeys.Windows) ? 8u : 0);
        return mask == 0 ? null : new((uint)KeyInterop.VirtualKeyFromKey(key), mask);
    }
}

internal sealed class HotKeyService : IDisposable
{
    private readonly HwndSource source = new(new HwndSourceParameters("Slightshot global shortcuts") { ParentWindow = new IntPtr(-3), Width = 0, Height = 0 });
    private readonly Action<int> onHotKey;
    public HotKeyService(Action<int> onHotKey) { this.onHotKey = onHotKey; source.AddHook(Hook); }
    public string[] Register(Settings settings)
    {
        var failures = new List<string>();
        HotKey[] keys = [settings.CaptureAreaHotKey, settings.SaveFullScreenHotKey, settings.CopyFullScreenHotKey];
        for (int i = 0; i < 3; i++) NativeMethods.UnregisterHotKey(source.Handle, i + 1);
        for (int i = 0; i < keys.Length; i++)
            if (!keys[i].IsEmpty && (!keys[i].IsValid || !NativeMethods.RegisterHotKey(source.Handle, i + 1, keys[i].Modifiers | 0x4000, keys[i].Key))) failures.Add(keys[i].ToString());
        return failures.ToArray();
    }
    private IntPtr Hook(IntPtr window, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message == NativeMethods.WmHotKey) { handled = true; onHotKey(wParam.ToInt32()); }
        return IntPtr.Zero;
    }
    public void Dispose()
    {
        for (int i = 1; i <= 3; i++) NativeMethods.UnregisterHotKey(source.Handle, i);
        source.RemoveHook(Hook); source.Dispose();
    }
}
