# Slightshot for Windows

The Windows app is a native .NET 10 WPF tray application. It starts from the
current Mac capture workflow and keeps the same floating controls, tool order,
colours, selection geometry and keyboard interactions. Windows 10 version 2004
or later, or Windows 11, is required.

## Download the preview

Download the portable [x64 ZIP](https://github.com/jmpijll/slightshot/releases/latest/download/Slightshot-windows-x64.zip)
or [ARM64 ZIP](https://github.com/jmpijll/slightshot/releases/latest/download/Slightshot-windows-arm64.zip)
from the latest release. Extract the ZIP and double-click its only file,
`Slightshot.exe`. The .NET runtime is bundled into the executable; you do not
need to install it. Windows preview binaries are unsigned; updates
are downloaded manually from Releases.

## Run and build

Install the [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0) on
Windows, then run from this repository:

```powershell
dotnet run --project Windows/Slightshot
```

Slightshot appears in the notification area. Double-click its icon or press
**Ctrl+Shift+9** to select an area. **Ctrl+Shift+8** saves the display under the
pointer; **Ctrl+Shift+7** copies it. These shortcuts can be changed in Settings.
If another app owns a shortcut, the tray reports it and remains available.

Create a portable app that includes its runtime:

```powershell
dotnet publish Windows/Slightshot -c Release -r win-x64 -p:PublishProfile=Portable -o Windows/artifacts/win-x64
dotnet publish Windows/Slightshot -c Release -r win-arm64 -p:PublishProfile=Portable -o Windows/artifacts/win-arm64
python Scripts/package_windows.py Windows/artifacts/win-x64 Windows/artifacts/Slightshot-windows-x64.zip --architecture x64
python Scripts/package_windows.py Windows/artifacts/win-arm64 Windows/artifacts/Slightshot-windows-arm64.zip --architecture arm64
```

The publish profile creates one `Slightshot.exe`, including its managed assemblies,
native libraries and .NET runtime. The package script rejects loose dependencies,
missing executables and mismatched architectures before creating a ZIP with that
one file at its root. CI uses the same profile for review artifacts and releases.

Run `Slightshot.exe` from any folder. No installer or administrator rights are
needed. On first launch, .NET extracts bundled native libraries into its cache
under `%TEMP%/.net`; later launches reuse that cache. Launch at login is available
in Settings. See [Microsoft's single-file deployment documentation](https://learn.microsoft.com/en-us/dotnet/core/deploying/single-file/overview).

## Mac parity

The overlay uses 30-point buttons, 18-point shared original vector icons, 6-point button corners,
9-point panel corners, 2-point button spacing, 4-point panel padding and 8-point
spacing from the selection. Tool order is Pen, Line, Arrow, Rectangle, Marker,
Text, Blur, Pixelate, Colour, Undo. Actions are Print, Copy, Save, Record and Close. The twelve swatches,
1–12-point thickness range, 45% dimming, selection handles, dimension badge and
136×174-point pixel loupe follow the Mac source. A frozen-screenshot blur and dark
tint reproduce the Mac HUD panel treatment without adding a WebView.

Selections can be moved, resized through all eight handles, nudged with arrows
(Shift moves ten points), made square with Shift, or copied on Ctrl-drag release.
Line/arrow/rectangle endpoints follow the Mac 45° constraint. Clicking outside
the current selection starts a new one and clears annotations. Enter or
double-click uses the configured default action. Esc/right-click cancels.

| While capturing | Action |
| --- | --- |
| Ctrl+A | Select this display |
| Ctrl+C | Copy selection |
| Ctrl+S | Save without prompting |
| Ctrl+Shift+S | Save as… |
| Ctrl+P | Print |
| Ctrl+Z | Undo annotation |
| Ctrl+X / Esc | Cancel |
| Ctrl+Enter while typing | Finish the text annotation |
| Enter while typing | Insert a newline |
| Esc while typing | Discard the draft |

The drawing tools share their renderer between the live canvas and exports, including
Catmull–Rom pen smoothing, arrowhead geometry and 35%-opacity highlighter strokes.
Copy includes a native bitmap and PNG clipboard representation. PNG, JPEG (90%
default quality) and LZW TIFF are supported. Save defaults to Pictures/Screenshots
and the same filename tokens as Mac; existing files receive `(2)`, `(3)` suffixes.
Optional copy-after-save, cursor inclusion, full display resolution, sound,
notifications, remembered tools and custom save directory are available.

Blur and Pixelate obscure a dragged rectangle using the frozen screenshot and
earlier annotations. The live preview, committed image and export share the
same compositor; later marks remain on top, and Undo removes the last effect.
Blur uses an 8-point radius and pixelation uses 12-point blocks, scaled for the
monitor's DPI. The cached committed image is reused while dragging. These tools
apply to screenshot output, not live video recordings.

Each monitor gets its own frozen image and overlay; negative desktop coordinates
and per-monitor DPI are retained. Native Win32 positions the borderless windows
in physical pixels, while selection/annotation coordinates use display points.
Focus goes to the display under the pointer after every overlay is presented.

## Validation and evidence

```powershell
dotnet run --project Windows/Slightshot.Core.Tests -c Release
dotnet build Windows/Slightshot -c Release
Start-Process Windows/Slightshot/bin/Release/net10.0-windows10.0.19041.0/Slightshot.exe -ArgumentList '--smoke-test', 'Windows/artifacts/parity' -Wait
Start-Process Windows/Slightshot/bin/Release/net10.0-windows10.0.19041.0/Slightshot.exe -ArgumentList '--recording-smoke-test', 'Windows/artifacts/recording' -Wait
```

The Windows workflow builds with warnings treated as errors, checks selection and
toolbar edge cases, renders native WPF overlay/settings fixtures, verifies export
sizes at 100%, 125%, 150% and 200%, and decodes PNG/JPEG/TIFF output. It uploads the
rendered images, a validation report and portable x64/ARM64 executables. For each
architecture, it creates and extracts the release ZIP, checks that it contains
only `Slightshot.exe`, and verifies the executable's architecture and version.
It runs both screenshot and recording smoke tests against the extracted x64 app
from a folder containing spaces. ARM64 is cross-built and inspected, but is not
executed by the x64 CI runner.

[Saved native Windows review evidence](review/windows-parity/README.md) includes
the overlay, light/dark settings fixtures, DPI/export results and the successful
Windows workflow run. These are synthetic native renderer checks.

On macOS, the platform-independent tests and Windows cross-compilation can run:

```bash
dotnet run --project Windows/Slightshot.Core.Tests -c Release
dotnet build Windows/Slightshot -c Release
```

The fixtures use synthetic content. They are native renderer evidence, not a
video of a person using the Windows desktop. Recording CI encodes moving synthetic
BGRA frames through the real Windows H.264 media pipeline, decodes video frames,
verifies every quality preset, cancellation, retry and temporary-file cleanup,
instantiates the actual recording HUD/save/progress windows and checks that their
native handles accept and retain capture exclusion. It renders timer/Stop and
light/dark save-time quality slider fixtures, and uploads images, MP4s and a report.
These verify native media and display-affinity registration, rather than desktop
capture or manual interaction. On 8 October 2026, the maintainer verified the
Windows app on a real Windows PC and reported that capture and recording worked
as expected, matching the Mac workflow. That acceptance did not include a
separate per-case record for clipboard/print/tray, mixed-DPI multi-monitor dragging
or keyboard focus. The Mac cannot run WPF.

Settings follow the Windows light/dark app preference with grouped panels,
rounded segmented tabs, switch controls and matching subdued colours. CI renders
both themes. The tray reuses the Mac menu artwork (tinted for the taskbar theme)
and the Windows executable icon is converted from the existing Mac app artwork.

Windows uses Segoe UI and the same original toolbar glyphs as Mac. The shared
source is `Resources/UI/icons.json`; Apple's system fonts remain platform-specific. Frosted material and text shadow are
approximations of AppKit rather than identical OS rendering. Windows update
delivery is manual; no signing, installer or automatic updater is provided in this
initial port. GDI screen capture targets the ordinary desktop; protected video
and HDR-specific colour management are outside this first version.

## Screen recording

Select an area, then click **Record** in the existing action bar. The frozen
overlay closes and a compact timer/Stop control appears beside the live area.
Stop opens a save dialog with file name, destination and a compression slider.
The choice is remembered for the next recording. This matches the Mac workflow
without extra setup before capture. Recording is silent; the existing cursor
and full-resolution capture preferences apply.

| Quality | Maximum side | Frame rate |
| --- | --- | --- |
| Small & fast | 1280 pixels | 15 fps |
| Balanced | 1920 pixels | 24 fps |
| High quality | 4096 pixels | 30 fps |

The source stays at up to 4096 pixels/30 fps until save succeeds or you explicitly
discard it. H.264 MP4 capture/export use the native Windows media encoder; no
external executable is required. All Slightshot windows are excluded through
Windows display affinity, including recording controls. The selected region is
cropped in physical monitor pixels; capture stays paced with one reusable BGRA
buffer and no queued backlog. Disconnected displays report an error.

Saving writes beside the destination, then replaces it after a complete MP4 is
finalized. Cancel or export failure keeps the source available for retry;
capture shortcuts are blocked while recording or saving. Quit cancels the
encoder, waits for its resources, and removes the temporary source directory.
The maintainer's 8 October 2026 desktop acceptance covers the overall recording
workflow. Exclusion under real Windows composition, mixed-DPI region placement
and cursor capture were not separately documented in that run.

The HUD uses an opaque native window with a rounded region. This avoids the
Windows 10 conflict between WPF per-pixel transparency and display affinity while
retaining the compact rounded timer/Stop styling.

Review the [recording controls, save-time quality dialog and native validation
report](review/windows-recording/README.md). Encoded video fixtures are available
in the linked Windows CI artifact; the evidence page states the desktop-capture
checks that remain unverified.

Native media references: [MediaStreamSource/MediaTranscoder recording](https://learn.microsoft.com/en-us/windows/uwp/audio-video-camera/screen-capture-video),
[excluding windows from capture](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowdisplayaffinity).

References: [Windows targeting from macOS](https://learn.microsoft.com/en-us/dotnet/core/tools/sdk-errors/netsdk1100),
[Microsoft's DPI guidance](https://learn.microsoft.com/en-us/windows/win32/hidpi/high-dpi-desktop-application-development-on-windows),
[WPF per-monitor DPI sample](https://github.com/microsoft/WPF-Samples/tree/main/PerMonitorDPI).
