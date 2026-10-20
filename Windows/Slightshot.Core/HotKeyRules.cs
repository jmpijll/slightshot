namespace Slightshot.Core;

public static class HotKeyRules
{
    public const uint PrintScreen = 0x2c;
    private const uint ModifierMask = 0x0f;

    /// Key 0 is the empty shortcut. Print Screen is Lightshot's Windows default,
    /// so it is the one key that may be registered without a modifier.
    public static bool IsValid(uint key, uint modifiers) =>
        key == 0 || key <= 0xff && (modifiers & ~ModifierMask) == 0 && (modifiers != 0 || key == PrintScreen);

    /// Windows takes Print Screen for its screen capture even when RegisterHotKey
    /// succeeds. A missing PrintScreenKeyForSnippingEnabled value means Windows 11's
    /// default, which is on; Windows 10 defaults to off.
    public static bool WindowsUsesPrintScreen(int? snippingSetting, int windowsBuild) =>
        snippingSetting is { } setting ? setting != 0 : windowsBuild >= 22000;
}
