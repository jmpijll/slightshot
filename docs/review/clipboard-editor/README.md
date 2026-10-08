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
`open -n build/Slightshot.app --args --clipboard-review`.
This bounded fixture seeds a 2003 × 1001 PNG with transparent margins and
semitransparent artwork, opens the real clipboard editor and creates the real menu
bar action. It requests no screen capture permission, registers no hotkeys and
exits after five minutes. It replaces the clipboard deliberately for review.

Check annotation and crop tools, Fit/100% and scrolling, menu-triggered busy
rejection, cancelled Save As followed by retry, native close followed by another
menu import, and PNG Copy/Save pixel dimensions and transparency. Capture the
native window and exported image for the PR. The fixture artwork is synthetic;
manual interaction with the actual AppKit editor supplies macOS acceptance evidence.
