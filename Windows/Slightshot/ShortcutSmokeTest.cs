using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace Slightshot;

// SendInput drives the real Settings fields on the isolated Windows CI desktop.
// Captures contain only the actual Settings HWND, with fixture input labelled here
// and in the report. No user settings file is read or written; Windows' Print
// Screen screen-capture setting is changed during the run and then restored.
internal static class ShortcutSmokeTest
{
    private const ushort LeftWin = 0x5b, RightWin = 0x5c, Control = 0xa2, Shift = 0xa0, Alt = 0xa4;
    private const ushort A = 0x41, F13 = 0x7c, PrintScreen = 0x2c;
    private const string SnippingValue = "PrintScreenKeyForSnippingEnabled";
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    internal static async Task RunAsync(string directory)
    {
        Directory.CreateDirectory(directory);
        // Windows opens its own screen capture on Print Screen while this setting
        // is on. Prove detection with it on, then turn it off for key input and
        // restore the original value.
        using var keyboard = Registry.CurrentUser.CreateSubKey(@"Control Panel\Keyboard");
        object? original = keyboard.GetValue(SnippingValue);
        try
        {
            keyboard.SetValue(SnippingValue, 1, RegistryValueKind.DWord); BroadcastSettingChange();
            await ExplainWindowsOwnedPrintScreenAsync(directory);
            keyboard.SetValue(SnippingValue, 0, RegistryValueKind.DWord); BroadcastSettingChange();
            await RunShortcutsAsync(directory);
        }
        finally
        {
            if (original == null) keyboard.DeleteValue(SnippingValue, false); else keyboard.SetValue(SnippingValue, original, RegistryValueKind.DWord);
            BroadcastSettingChange();
        }
    }

    private static async Task ExplainWindowsOwnedPrintScreenAsync(string directory)
    {
        var settings = new Settings { PlaySound = false, CaptureAreaHotKey = new(PrintScreen, 0) };
        HotKey[] failures;
        using (var service = new HotKeyService(_ => { })) failures = service.Register(settings);
        Require(HotKeyService.WindowsUsesPrintScreen() && failures.SequenceEqual([new HotKey(PrintScreen, 0)]), "with Windows' Print Screen screen capture on, registration reports Print Screen unavailable: " + string.Join(", ", failures));
        var window = new SettingsWindow(settings, false, failures) { Title = "Slightshot Settings · Windows Print Screen capture on" };
        try
        {
            window.Show(); window.Activate();
            await ShowShortcutsAsync(window);
            var note = ShortcutNote(window);
            Require(note.IsVisible && note.Text.StartsWith("Windows is using Print Screen to open screen capture. Turn off “Use the Print screen key to open screen capture”"), "Settings explains why Print Screen is unavailable");
            CaptureWindow(window, Path.Combine(directory, "shortcut-print-screen-unavailable-window.png"));
        }
        finally { window.Close(); }
    }

    private static async Task RunShortcutsAsync(string directory)
    {
        string sourceCommit = Environment.GetEnvironmentVariable("SLIGHTSHOT_SOURCE_COMMIT")
            ?? Environment.GetEnvironmentVariable("GITHUB_SHA") ?? "local source commit not supplied";
        var checks = new List<string>();
        var keyEvents = new List<object>();
        var settings = new Settings { PlaySound = false };
        var window = new SettingsWindow(settings, false) { Title = "Slightshot Settings · automated shortcut fixture" };
        try
        {
            window.Show(); window.Activate();
            await ShowShortcutsAsync(window);
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

            await FocusAsync(window, save); await ChordAsync(Control, LeftWin, F13);
            Require(settings.SaveFullScreenHotKey == new HotKey(F13, 10) && save.Text == "Ctrl+Win+F13", "Windows retains Control");
            await FocusAsync(window, copy); await ChordAsync(Shift, Alt, RightWin, F13);
            Require(settings.CopyFullScreenHotKey == new HotKey(F13, 13) && copy.Text == "Shift+Alt+Win+F13", "Windows retains Shift and Alt via WPF SystemKey");
            await FocusAsync(window, area); await ChordAsync(Control, Shift, Alt, LeftWin, F13);
            Require(settings.CaptureAreaHotKey == new HotKey(F13, 15) && area.Text == "Ctrl+Shift+Alt+Win+F13", "all four modifiers survive recording");
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

            await FocusAsync(window, copy); await ChordAsync(Control, LeftWin, F13);
            Require(settings.CopyFullScreenHotKey == new HotKey(F13, 13) && copy.Text == "Shift+Alt+Win+F13"
                && Equals(copy.ToolTip, "This shortcut is already assigned to another capture action."), "duplicate Windows shortcut is rejected without replacing the field");
            await ChordAsync(0x1b);
            Require(settings.CopyFullScreenHotKey.IsEmpty && copy.Text == "None" && copy.ToolTip == null && window.IsVisible, "Escape clears the focused shortcut and keeps Settings open");
            await ChordAsync(Shift, Alt, RightWin, F13);
            Require(settings.CopyFullScreenHotKey == new HotKey(F13, 13) && copy.ToolTip == null, "valid chord clears duplicate feedback");
            checks.Add("Duplicate assignment remains rejected; Escape clears only the focused shortcut; a subsequent valid chord clears feedback.");
            CaptureWindow(window, Path.Combine(directory, "shortcut-combinations-window.png"));

            await FocusAsync(window, area); await ChordAsync(PrintScreen);
            await CloseScreenSnippingAsync(); await FocusAsync(window, area);
            Require(settings.CaptureAreaHotKey == new HotKey(PrintScreen, 0) && area.Text == "Print Screen", $"Print Screen alone records through the real field: observed field={area.Text}, model key={settings.CaptureAreaHotKey.Key}, modifiers={settings.CaptureAreaHotKey.Modifiers}");
            var note = ShortcutNote(window);
            Require(!note.IsVisible, "with Windows' Print Screen screen capture off, Settings shows no warning for Print Screen");
            CaptureWindow(window, Path.Combine(directory, "shortcut-print-screen-window.png"));
            await ChordAsync(LeftWin, F13);
            Require(settings.CaptureAreaHotKey == new HotKey(F13, 8) && area.Text == "Win+F13", "Win+F13 replaces Print Screen");
            checks.Add("Print Screen without a modifier records through native key-up input; other bare keys stay ignored.");

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
            HotKey[] failures = service.Register(restored);
            Require(failures.Length == 0, "production RegisterHotKey accepts the recorded combinations: " + string.Join(", ", failures));
            await ChordAsync(LeftWin, F13);
            await ChordAsync(Control, RightWin, F13);
            await ChordAsync(Shift, Alt, LeftWin, F13);
            Require(callbacks.SequenceEqual(new[] { 1, 2, 3 }), "recorded shortcuts trigger the three real global hotkey callbacks after Settings closes");
            await ChordAsync(F13); await ChordAsync(Control, F13); await ChordAsync(Shift, Alt, F13);
            Require(callbacks.SequenceEqual(new[] { 1, 2, 3 }), "the same keys without Windows cannot trigger the recorded global shortcuts");
        }
        checks.Add("Recorded settings JSON roundtrip preserves Windows modifiers. After Settings closes, production RegisterHotKey registration and native SendInput produce callbacks 1, 2, 3; removing Windows produces none.");
        object? snippingSetting = Registry.GetValue(@"HKEY_CURRENT_USER\Control Panel\Keyboard", SnippingValue, null);
        var printScreenCallbacks = new List<int>();
        var printScreenInjection = new List<object>();
        using (var service = new HotKeyService(printScreenCallbacks.Add))
        {
            HotKey[] failures = service.Register(new Settings { CaptureAreaHotKey = new(PrintScreen, 0), SaveFullScreenHotKey = new(F13, 0), CopyFullScreenHotKey = new(0, 0) });
            Require(failures.SequenceEqual([new HotKey(F13, 0)]), $"RegisterHotKey accepts Print Screen alone and bare F13 stays rejected (PrintScreenKeyForSnippingEnabled={snippingSetting ?? "not set"}): " + string.Join(", ", failures));
            // The CI shell keeps Print Screen for its capture even after the
            // setting is cleared, so record each form, its edge and the foreground.
            (string Name, ushort Key, ushort Scan, uint Flags)[] forms =
                [("virtual key, extended", PrintScreen, 0, 1), ("virtual key", PrintScreen, 0, 0), ("virtual key and scan 0x37, extended", PrintScreen, 0x37, 1), ("scan code 0x37, extended", 0, 0x37, 9)];
            foreach (var form in forms)
            {
                int before = printScreenCallbacks.Count;
                SendRaw(form.Key, form.Scan, form.Flags); await Task.Delay(200);
                int afterDown = printScreenCallbacks.Count - before;
                SendRaw(form.Key, form.Scan, form.Flags | 2); await Task.Delay(300);
                string foreground = DescribeForeground();
                printScreenInjection.Add(new { form = form.Name, callbacksAfterKeyDown = afterDown, callbacksAfterKeyUp = printScreenCallbacks.Count - before - afterDown, foreground });
                await CloseScreenSnippingAsync();
            }
            File.WriteAllText(Path.Combine(directory, "shortcut-print-screen-injection.json"), JsonSerializer.Serialize(new { sourceCommit, printScreenKeyForSnippingEnabled = snippingSetting?.ToString() ?? "not set", printScreenInjection }, JsonOptions));
            Require(printScreenCallbacks.All(id => id == 1), "only the capture-area hotkey can fire for Print Screen");
            int printScreenCount = printScreenCallbacks.Count;
            await ChordAsync(F13);
            Require(printScreenCallbacks.Count == printScreenCount, "bare F13 never triggers a global hotkey");
        }
        checks.Add("With Windows' Print Screen screen capture on, registration reports Print Screen unavailable and Settings explains the setting. With it off, production RegisterHotKey registers Print Screen without a modifier; bare F13 is rejected and produces no callback. Injected Print Screen results are in shortcut-print-screen-injection.json.");
        File.WriteAllText(Path.Combine(directory, "shortcut-validation.json"), JsonSerializer.Serialize(new
        {
            platform = "Windows / native WPF Settings / Win32 global hotkeys",
            sourceCommit, source = "Automated native Settings fixture with real SendInput and RegisterHotKey; screenshots are cropped composed desktop pixels.",
            printScreenKeyForSnippingEnabled = snippingSetting?.ToString() ?? "not set", printScreenInjection,
            fixtureInputs = new[] { "Windows Print Screen screen capture on, then off", "Print Screen", "Left Win+F13", "Right Win+F13 after Ctrl+Shift+A", "Ctrl+Win+F13", "Shift+Alt+Win+F13", "Ctrl+Shift+Alt+Win+F13", "Ctrl+Shift+A", "bare modifiers", "duplicate assignment", "Escape" },
            recorded = new[] { restored.CaptureAreaHotKey, restored.SaveFullScreenHotKey, restored.CopyFullScreenHotKey }, globalCallbacks = callbacks, checks
        }, JsonOptions));
    }

    // Windows' capture overlay appears shortly after Print Screen and would
    // take the following input, so close it before continuing.
    private static async Task CloseScreenSnippingAsync()
    {
        for (int attempt = 0; attempt < 15; attempt++)
        {
            if (DescribeForeground().Contains("Screen Snipping")) { await ChordAsync(0x1b); await Task.Delay(300); return; }
            await Task.Delay(100);
        }
    }

    private static async Task ShowShortcutsAsync(Window window)
    {
        var tabs = Descendants((DependencyObject)window.Content).OfType<TabControl>().Single();
        tabs.SelectedItem = tabs.Items.Cast<TabItem>().Single(tab => Equals(tab.Header, "Shortcuts"));
        window.UpdateLayout();
        await Task.Delay(250);
    }

    private static TextBlock ShortcutNote(Window window) =>
        Descendants((DependencyObject)window.Content).OfType<TextBlock>().Single(block => AutomationProperties.GetName(block) == "Shortcut availability");

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

    private static void SendRaw(ushort key, ushort scan, uint flags)
    {
        Input[] inputs = [new() { Type = 1, Data = new InputUnion { Keyboard = new KeyboardInput { Key = key, Scan = scan, Flags = flags } } }];
        Require(SendInput(1, inputs, Marshal.SizeOf<Input>()) == 1, $"SendInput accepts key 0x{key:X2}, scan 0x{scan:X2}, flags {flags}, Win32 error {Marshal.GetLastWin32Error()}");
    }

    private static void SendKey(ushort key, bool release)
    {
        // The Windows and Print Screen keys are extended virtual keys; key-up reverses each
        // corresponding down event rather than bypassing WPF's keyboard state.
        uint flags = (release ? 2u : 0) | (key is LeftWin or RightWin or PrintScreen ? 1u : 0);
        Input[] inputs = [new() { Type = 1, Data = new InputUnion { Keyboard = new KeyboardInput { Key = key, Flags = flags } } }];
        Require(SendInput(1, inputs, Marshal.SizeOf<Input>()) == 1, $"SendInput accepts key 0x{key:X2}, release={release}, Win32 error {Marshal.GetLastWin32Error()}");
    }

    private static void CaptureWindow(Window window, string path)
    {
        IntPtr handle = new WindowInteropHelper(window).Handle;
        Require(window.IsVisible && GetForegroundWindow() == handle, $"captured native Settings window \"{window.Title}\" is visible in the foreground; foreground is {DescribeForeground()}");
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
    private static string DescribeForeground()
    {
        IntPtr foreground = GetForegroundWindow();
        var title = new System.Text.StringBuilder(256); var className = new System.Text.StringBuilder(256);
        GetWindowText(foreground, title, title.Capacity); GetClassName(foreground, className, className.Capacity);
        GetWindowThreadProcessId(foreground, out uint process);
        return $"0x{foreground.ToInt64():X} class={className} title=\"{title}\" process={process} (this process {Environment.ProcessId})";
    }
    private static void BroadcastSettingChange() => SendMessageTimeout(new IntPtr(0xffff), 0x1a, UIntPtr.Zero, @"Control Panel\Keyboard", 2, 1000, out _);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr SendMessageTimeout(IntPtr window, uint message, UIntPtr wParam, string lParam, uint flags, uint timeout, out UIntPtr result);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, System.Text.StringBuilder text, int count);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, System.Text.StringBuilder text, int count);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] private static extern short GetKeyState(int key);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
}
