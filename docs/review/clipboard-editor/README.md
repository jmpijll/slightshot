# Clipboard image editor review

The menu-bar/tray **Edit Image from Clipboard** action reads the clipboard only
when requested. It opens the existing crop/annotation editor in a normal native
window, with Fit and 100% viewing. Native PNG/TIFF decoding preserves source pixels
and alpha. Bitmap fallback is supported on Windows. File URLs/drops are ignored.
Screen capture, imported-image editing and modal output share one session gate.
Recording is unavailable for imports. Cancelled/failed output retains the editor;
success, Escape and native close release ownership.

## Repeatable checks

- `swift build`, `swift test`, `swiftlint --strict --quiet`
- `dotnet run --project Windows/Slightshot.Core.Tests -c Release`
- `dotnet build Windows/Slightshot -c Release`
- On Windows: `Slightshot.exe --clipboard-smoke-test <evidence-directory>`

The native Windows smoke test runs the real tray action route with a synthetic
2003 × 1001 transparent clipboard PNG at 192 DPI and annotation fixture. It saves
a desktop screenshot of the actual WPF window, the source image, a real PNG export
and `clipboard-validation.json`. It checks empty/text/file-drop rejection, PNG
priority over Bitmap, Fit/100%, alpha, full pixel resolution with the screenshot
resolution setting disabled, output cancellation/write failure/retry, busy input
rejection and native close. CI publishes `windows-native-clipboard-evidence`.
The source/annotation fixture is synthetic; the WPF window and output pipeline are real.

## macOS manual acceptance

Build `VERSION=0.0.0-review BUILD=1 ./Scripts/bundle.sh` and launch
`open -n build/Slightshot.app --args --clipboard-review <evidence-directory>`.
This bounded fixture seeds a 2003 × 1001 PNG with transparent margins and
semitransparent artwork, opens the real clipboard editor and creates the real menu
bar action. It requests no screen capture permission, registers no hotkeys and
exits after five minutes. It holds original clipboard data only in memory and
restores the seed or its own Copy exports on normal termination. A clipboard
changed externally is preserved. It writes source/export PNG and JSON under the
provided directory (default `build/clipboard-review`) for pixel/alpha inspection
without reading the general clipboard.

Check annotation and crop tools, Fit/100% and scrolling, menu-triggered busy
rejection, cancelled Save As followed by retry, native close followed by another
menu import, and PNG Copy/Save pixel dimensions and transparency. Capture the
native window and exported image for the PR. The fixture artwork is synthetic;
manual interaction with the actual AppKit editor supplies macOS acceptance evidence.

## Captured Windows evidence

Native WPF smoke and all Windows build/parity/recording/package checks passed in
[run 37776259212](https://github.com/jmpijll/slightshot/actions/runs/37776259212)
at source commit `7032ff57d3d84cd2138060824cb467435a4f9ad0`.

![Actual WPF clipboard editor window, synthetic image and annotations](windows/clipboard-editor-window.png)

- [Native edited PNG export](windows/clipboard-edited-export.png), 2003 × 1001 pixels with alpha
- [Synthetic original clipboard PNG](windows/clipboard-source.png)
- [Native validation checks](windows/clipboard-validation.json)
- [Run, source, fixture and SHA-256 provenance](windows/provenance.json)

The screenshot is a desktop capture of the actual application window. The source
and annotation contents are repeatable synthetic fixtures. They do not claim a
human Windows acceptance session.
