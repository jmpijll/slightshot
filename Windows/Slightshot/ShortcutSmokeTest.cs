using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using Forms = System.Windows.Forms;

namespace Slightshot;

// SendInput drives the real Settings fields on the isolated Windows CI desktop.
// Captures contain only the actual Settings HWND, with fixture input labelled here
// and in the report. No user settings file is read or written.
internal static class ShortcutSmokeTest
{
    private const ushort LeftWin = 0x5b, RightWin = 0x5c, Control = 0xa2, Shift = 0xa0, Alt = 0xa4;
    private const ushort A = 0x41, F13 = 0x7c, F14 = 0x7d, F15 = 0x7e, F16 = 0x7f;
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    internal static async Task RunAsync(string directory)
    {
        Directory.CreateDirectory(directory);
        string sourceCommit = Environment.GetEnvironmentVariable("SLIGHTSHOT_SOURCE_COMMIT")
            ?? Environment.GetEnvironmentVariable("GITHUB_SHA") ?? "local source commit not supplied";
        var checks = new List<string>();
        var keyEvents = new List<object>();
        var settings = new Settings { PlaySound = false };
        var window = new SettingsWindow(settings, false) { Title = "Slightshot Settings · automated shortcut fixture" };
        try
        {
            window.Show(); window.Activate();
            var tabs = Descendants((DependencyObject)window.Content).OfType<TabControl>().Single();
            tabs.SelectedItem = tabs.Items.Cast<TabItem>().Single(tab => Equals(tab.Header, "Shortcuts"));
            window.UpdateLayout();
            await Task.Delay(250);
            var fields = Descendants((DependencyObject)window.Content).OfType<TextBox>()
                .ToDictionary(field => AutomationProperties.GetName(field));
            TextBox area = fields["Capture area"], save = fields["Capture full screen"], copy = fields["Copy full screen"];
            void ObserveKey(string phase, KeyEventArgs e)
            {
                var field = Keyboard.FocusedElement as TextBox;
                keyEvents.Add(new
                {
                    phase, key = e.Key.ToString(), systemKey = e.SystemKey.ToString(), handled = e.Handled,
                    modifiers = Keyboard.Modifiers.ToString(), leftWinDown = Keyboard.IsKeyDown(Key.LWin), rightWinDown = Keyboard.IsKeyDown(Key.RWin),
                    nativeLeftWinDown = (GetKeyState(LeftWin) & 0x8000) != 0, nativeRightWinDown = (GetKeyState(RightWin) & 0x8000) != 0,
                    asyncLeftWinDown = (GetAsyncKeyState(LeftWin) & 0x8000) != 0, asyncRightWinDown = (GetAsyncKeyState(RightWin) & 0x8000) != 0,
                    focusedField = field == null ? null : AutomationProperties.GetName(field), fieldText = field?.Text,
                    area = settings.CaptureAreaHotKey, save = settings.SaveFullScreenHotKey, copy = settings.CopyFullScreenHotKey,
                    foreground = GetForegroundWindow().ToInt64().ToString("X"), settingsHandle = new WindowInteropHelper(window).Handle.ToInt64().ToString("X")
                });
            }
            // The Window preview route observes state before the production field
            // handler. These handlers were added after the production handler and
            // also run when it marks the event handled, exposing its actual result.
            window.AddHandler(Keyboard.PreviewKeyDownEvent, new KeyEventHandler((_, e) => ObserveKey("window-before-field", e)), true);
            foreach (var field in new[] { area, save, copy })
                field.AddHandler(Keyboard.PreviewKeyDownEvent, new KeyEventHandler((_, e) => ObserveKey("field-after-recording", e)), true);
            await FocusAsync(window, area);
            CaptureWindow(window, Path.Combine(directory, "shortcut-before-window.png"));

            await ChordAsync(LeftWin, F13);
            // Flush diagnostics and real desktop pixels before asserting so the
            // identical fixture also supplies review evidence for the old failure.
            CaptureWindow(window, Path.Combine(directory, "shortcut-left-win-window.png"));
            File.WriteAllText(Path.Combine(directory, "shortcut-observation.json"), JsonSerializer.Serialize(new
            {
                platform = "Windows / native WPF Settings",
                sourceCommit, source = "Automated SendInput on the real Shortcuts tab; cropped composed desktop pixels.",
                input = "Left Windows + F13", expected = "Win+F13", observed = area.Text,
                recorded = settings.CaptureAreaHotKey, passed = settings.CaptureAreaHotKey == new HotKey(F13, 8)
            }, JsonOptions));
            Require(settings.CaptureAreaHotKey == new HotKey(F13, 8) && area.Text == "Win+F13", "left Windows key is recorded by the real field");
            // F18 was accepted by SendInput on the CI desktop but never reached
            // WPF. Reuse the proven F13 input after first changing the model so
            // a dropped right-Windows chord cannot pass through an unchanged field.
            await ChordAsync(Control, Shift, A);
            Require(settings.CaptureAreaHotKey == new HotKey(A, 6) && area.Text == "Ctrl+Shift+A", "ordinary chord changes the field before testing right Windows");
            await ChordAsync(RightWin, F13);
            File.WriteAllText(Path.Combine(directory, "shortcut-key-events.json"), JsonSerializer.Serialize(new
            {
                sourceCommit, input = "Right Windows + F13 after Ctrl+Shift+A", expected = "Win+F13", observed = area.Text,
                recorded = settings.CaptureAreaHotKey, sendInput = new { windowsScan = 0, windowsFlags = "KEYEVENTF_EXTENDEDKEY", rightWinVirtualKey = RightWin, mainVirtualKey = F13 },
                keyEvents
            }, JsonOptions));
            CaptureWindow(window, Path.Combine(directory, "shortcut-right-win-window.png"));
            Require(settings.CaptureAreaHotKey == new HotKey(F13, 8) && area.Text == "Win+F13", $"right Windows key replaces Ctrl+Shift+A through the real field: expected Win+F13 / key={F13}, modifiers=8; observed field={area.Text}, model key={settings.CaptureAreaHotKey.Key}, modifiers={settings.CaptureAreaHotKey.Modifiers}");
            checks.Add("Left and right Windows + F13 both record through real native key input; right Windows replaces a distinct Ctrl+Shift+A value.");

            await FocusAsync(window, save); await ChordAsync(Control, LeftWin, F14);
            Require(settings.SaveFullScreenHotKey == new HotKey(F14, 10) && save.Text == "Ctrl+Win+F14", "Windows retains Control");
            await FocusAsync(window, copy); await ChordAsync(Shift, Alt, RightWin, F15);
            Require(settings.CopyFullScreenHotKey == new HotKey(F15, 13) && copy.Text == "Shift+Alt+Win+F15", "Windows retains Shift and Alt via WPF SystemKey");
            await FocusAsync(window, area); await ChordAsync(Control, Shift, Alt, LeftWin, F16);
            Require(settings.CaptureAreaHotKey == new HotKey(F16, 15) && area.Text == "Ctrl+Shift+Alt+Win+F16", "all four modifiers survive recording");
            await ChordAsync(Control, Shift, A);
            Require(settings.CaptureAreaHotKey == new HotKey(A, 6) && area.Text == "Ctrl+Shift+A", "existing shortcuts without Windows retain their modifiers");
            await ChordAsync(LeftWin, F13);
            checks.Add("Windows with Control, Shift, Alt and all modifiers retains the full modifier mask; an existing Ctrl+Shift shortcut still records correctly.");

            foreach (ushort modifier in new[] { Control, Shift, Alt, LeftWin, RightWin })
            {
                HotKey previous = settings.CaptureAreaHotKey;
                SendKey(modifier, false); await Task.Delay(80);
                Require(settings.CaptureAreaHotKey == previous && area.Text == previous.ToString(), $"bare modifier 0x{modifier:X2} does not replace the shortcut");
                // A bare Win release opens Start. Complete the proven F13 chord
                // after the assertion so the following native field keeps focus.
                if (modifier is LeftWin or RightWin) { SendKey(F13, false); await Task.Delay(80); SendKey(F13, true); }
                SendKey(modifier, true); await Task.Delay(80);
                if (modifier is LeftWin or RightWin) await ChordAsync(LeftWin, F13);
            }
            await ChordAsync(A);
            Require(settings.CaptureAreaHotKey == new HotKey(F13, 8) && area.Text == "Win+F13", "unmodified key leaves the shortcut unchanged");
            checks.Add("Bare Control, Shift, Alt and both Windows keys leave the field unchanged while held; a key without modifiers is ignored.");

            await FocusAsync(window, copy); await ChordAsync(Control, LeftWin, F14);
            Require(settings.CopyFullScreenHotKey == new HotKey(F15, 13) && copy.Text == "Shift+Alt+Win+F15"
                && Equals(copy.ToolTip, "This shortcut is already assigned to another capture action."), "duplicate Windows shortcut is rejected without replacing the field");
            await ChordAsync(0x1b);
            Require(settings.CopyFullScreenHotKey.IsEmpty && copy.Text == "None" && copy.ToolTip == null && window.IsVisible, "Escape clears the focused shortcut and keeps Settings open");
            await ChordAsync(Shift, Alt, RightWin, F15);
            Require(settings.CopyFullScreenHotKey == new HotKey(F15, 13) && copy.ToolTip == null, "valid chord clears duplicate feedback");
            checks.Add("Duplicate assignment remains rejected; Escape clears only the focused shortcut; a subsequent valid chord clears feedback.");
            CaptureWindow(window, Path.Combine(directory, "shortcut-combinations-window.png"));
        }
        finally
        {
            File.WriteAllText(Path.Combine(directory, "shortcut-all-key-events.json"), JsonSerializer.Serialize(new { sourceCommit, keyEvents }, JsonOptions));
            // Release injected modifiers even when the baseline regression fails.
            foreach (ushort modifier in new[] { Control, Shift, Alt, LeftWin, RightWin }) SendKey(modifier, true);
            window.Close();
        }

        var restored = JsonSerializer.Deserialize<Settings>(JsonSerializer.Serialize(settings))!;
        Require(restored.CaptureAreaHotKey == settings.CaptureAreaHotKey && restored.SaveFullScreenHotKey == settings.SaveFullScreenHotKey
            && restored.CopyFullScreenHotKey == settings.CopyFullScreenHotKey, "recorded Windows modifiers survive settings JSON roundtrip");
        var callbacks = new List<int>();
        using (var service = new HotKeyService(callbacks.Add))
        {
            string[] failures = service.Register(restored);
            Require(failures.Length == 0, "production RegisterHotKey accepts the recorded combinations: " + string.Join(", ", failures));
            await ChordAsync(LeftWin, F13);
            await ChordAsync(Control, RightWin, F14);
            await ChordAsync(Shift, Alt, LeftWin, F15);
            Require(callbacks.SequenceEqual(new[] { 1, 2, 3 }), "recorded shortcuts trigger the three real global hotkey callbacks after Settings closes");
            await ChordAsync(F13); await ChordAsync(Control, F14); await ChordAsync(Shift, Alt, F15);
            Require(callbacks.SequenceEqual(new[] { 1, 2, 3 }), "the same keys without Windows cannot trigger the recorded global shortcuts");
        }
        checks.Add("Recorded settings JSON roundtrip preserves Windows modifiers. After Settings closes, production RegisterHotKey registration and native SendInput produce callbacks 1, 2, 3; removing Windows produces none.");
        File.WriteAllText(Path.Combine(directory, "shortcut-validation.json"), JsonSerializer.Serialize(new
        {
            platform = "Windows / native WPF Settings / Win32 global hotkeys",
            sourceCommit, source = "Automated native Settings fixture with real SendInput and RegisterHotKey; screenshots are cropped composed desktop pixels.",
            fixtureInputs = new[] { "Left Win+F13", "Right Win+F13 after Ctrl+Shift+A", "Ctrl+Win+F14", "Shift+Alt+Win+F15", "Ctrl+Shift+Alt+Win+F16", "Ctrl+Shift+A", "bare modifiers", "duplicate assignment", "Escape" },
            recorded = new[] { restored.CaptureAreaHotKey, restored.SaveFullScreenHotKey, restored.CopyFullScreenHotKey }, globalCallbacks = callbacks, checks
        }, JsonOptions));
    }

    private static async Task FocusAsync(Window window, TextBox field)
    {
        window.Activate(); field.Focus(); field.SelectAll(); await Task.Delay(100);
        Require(GetForegroundWindow() == new WindowInteropHelper(window).Handle && field.IsKeyboardFocused, "native Settings window and target field have keyboard focus");
    }

    private static async Task ChordAsync(params ushort[] keys)
    {
        try
        {
            foreach (ushort key in keys) { SendKey(key, false); await Task.Delay(80); }
        }
        finally
        {
            foreach (ushort key in keys.Reverse()) SendKey(key, true);
        }
        await Task.Delay(120);
    }

    private static void SendKey(ushort key, bool release)
    {
        // The Windows keys are extended virtual keys; key-up reverses each
        // corresponding down event rather than bypassing WPF's keyboard state.
        uint flags = (release ? 2u : 0) | (key is LeftWin or RightWin ? 1u : 0);
        Input[] inputs = [new() { Type = 1, Data = new InputUnion { Keyboard = new KeyboardInput { Key = key, Flags = flags } } }];
        Require(SendInput(1, inputs, Marshal.SizeOf<Input>()) == 1, $"SendInput accepts key 0x{key:X2}, release={release}, Win32 error {Marshal.GetLastWin32Error()}");
    }

    private static void CaptureWindow(Window window, string path)
    {
        IntPtr handle = new WindowInteropHelper(window).Handle;
        Require(window.IsVisible && GetForegroundWindow() == handle, "captured native Settings window is visible in the foreground");
        Require(RecordingNative.GetWindowRect(handle, out var rect), "native Settings window has capture bounds");
        var bounds = new System.Drawing.Rectangle(rect.Left, rect.Top, rect.Right - rect.Left, rect.Bottom - rect.Top);
        Require(bounds.Width > 0 && bounds.Height > 0 && Forms.Screen.FromHandle(handle).Bounds.Contains(bounds), "native Settings capture fits on its monitor");
        NativeMethods.DwmFlush();
        using var bitmap = new System.Drawing.Bitmap(bounds.Width, bounds.Height);
        using var graphics = System.Drawing.Graphics.FromImage(bitmap);
        graphics.CopyFromScreen(bounds.Location, System.Drawing.Point.Empty, bounds.Size);
        bitmap.Save(path, System.Drawing.Imaging.ImageFormat.Png);
    }

    private static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
    {
        for (int index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
        {
            var child = VisualTreeHelper.GetChild(parent, index); yield return child;
            foreach (var descendant in Descendants(child)) yield return descendant;
        }
    }
    private static void Require(bool condition, string check) { if (!condition) throw new InvalidOperationException("Windows shortcut smoke test failed: " + check); }
    [StructLayout(LayoutKind.Sequential)] private struct Input { public uint Type; public InputUnion Data; }
    [StructLayout(LayoutKind.Explicit)] private struct InputUnion
    {
        [FieldOffset(0)] public KeyboardInput Keyboard;
        [FieldOffset(0)] public MouseInput Mouse;
    }
    [StructLayout(LayoutKind.Sequential)] private struct KeyboardInput { public ushort Key, Scan; public uint Flags, Time; public UIntPtr ExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] private struct MouseInput { public int X, Y; public uint Data, Flags, Time; public UIntPtr ExtraInfo; }
    [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint count, Input[] inputs, int size);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern short GetKeyState(int key);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
}
