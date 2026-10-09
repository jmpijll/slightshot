# Windows-key shortcut review

These are real WPF Settings windows on the isolated Windows Server 2025 CI
desktop. The automated native fixture opens Shortcuts, focuses Capture area and
sends Left Win+F13. Captures are composed desktop pixels cropped to the Settings
window. Fixture settings are created in memory; personal settings are not read
or saved.

The baseline capture uses source `3f0cccd655ab1e6bebdcb771260df5a699ac964a`.
The field stays at Ctrl+Shift+9 and the regression assertion fails, confirming
the report. The fixed capture uses source
`8ea2f650467e658183035e841bbb5c628c8fa219`; the same input displays Win+F13.
Workflow URLs, capture inputs and file hashes are in [capture-source.json](capture-source.json).

![Windows before: Win+F13 leaves the old shortcut unchanged](windows-before.png)
![Windows after: Win+F13 is recorded](windows-after.png)

The baseline and fixed observations are preserved separately. The full native
fixture additionally checks the right Windows key, combinations with other
modifiers, modifier-only input, duplicate assignment, Escape, settings JSON
roundtrip and production global hotkey callbacks after Settings closes. CI
also runs the fixture against the extracted portable x64 executable.

## Exact-release validation

The Windows job in the [1.4.2 release workflow](https://github.com/jmpijll/slightshot/actions/runs/37989426323)
passed using source `b25fd6c98b3289430cdec3088558f77e967c70ae`. Both the native
build and the extracted single-file x64 download passed the complete fixture,
including actual global callbacks for all three capture actions and no callbacks
when the Windows modifier was omitted. Their reports are preserved as
[native validation](native-shortcut-validation.json) and
[portable validation](portable-shortcut-validation.json).

The following real Settings-window captures use that same release source.
The right-Windows test first changes the field to Ctrl+Shift+A, then verifies that
Right Win+F13 replaces it. The combinations capture follows the modifier,
duplicate-assignment and Escape checks.

![Right Windows key records the shortcut](windows-right-win.png)
![Windows modifiers combined with Ctrl, Shift and Alt](windows-combinations.png)

Windows core checks, screenshot/clipboard/recording/delayed-capture fixtures,
package inspection and x64 installer lifecycle checks also passed in the release
job. ARM64 downloads are cross-built and inspected; native execution uses x64.
