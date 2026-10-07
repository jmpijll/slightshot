# Slightshot for Windows

The Windows app is a native .NET 10 WPF tray application. It starts from the
current Mac capture workflow and keeps the same floating controls, tool order,
colours, selection geometry and keyboard interactions. Windows 10/11 is required.

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
dotnet publish Windows/Slightshot -c Release -r win-x64 --self-contained true -o Windows/artifacts/win-x64
dotnet publish Windows/Slightshot -c Release -r win-arm64 --self-contained true -o Windows/artifacts/win-arm64
```

Run `Slightshot.exe` from the published folder. No installer or administrator
rights are needed. Launch at login is available in Settings.

## Mac parity

The overlay uses 30-point buttons, 15-point vector icons, 6-point button corners,
9-point panel corners, 2-point button spacing, 4-point panel padding and 8-point
spacing from the selection. Tool order is Pen, Line, Arrow, Rectangle, Marker,
Text, Colour, Undo. Actions are Print, Copy, Save and Close. The twelve swatches,
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

All six tools share their renderer between the live canvas and exports, including
Catmull–Rom pen smoothing, arrowhead geometry and 35%-opacity highlighter strokes.
Copy includes a native bitmap and PNG clipboard representation. PNG, JPEG (90%
default quality) and LZW TIFF are supported. Save defaults to Pictures/Screenshots
and the same filename tokens as Mac; existing files receive `(2)`, `(3)` suffixes.
Optional copy-after-save, cursor inclusion, full display resolution, sound,
notifications, remembered tools and custom save directory are available.

Each monitor gets its own frozen image and overlay; negative desktop coordinates
and per-monitor DPI are retained. Native Win32 positions the borderless windows
in physical pixels, while selection/annotation coordinates use display points.
Focus goes to the display under the pointer after every overlay is presented.

## Validation and evidence

```powershell
dotnet run --project Windows/Slightshot.Core.Tests -c Release
dotnet build Windows/Slightshot -c Release
Start-Process Windows/Slightshot/bin/Release/net10.0-windows/Slightshot.exe -ArgumentList '--smoke-test', 'Windows/artifacts/parity' -Wait
```

The Windows workflow builds with warnings treated as errors, checks selection and
toolbar edge cases, renders native WPF overlay/settings fixtures, verifies export
sizes at 100%, 125%, 150% and 200%, and decodes PNG/JPEG/TIFF output. It uploads the
rendered images, a validation report and portable x64/ARM64 app folders.

[Saved native Windows review evidence](review/windows-parity/README.md) includes
the overlay, light/dark settings fixtures, DPI/export results and the successful
Windows workflow run. These are synthetic native renderer checks.

On macOS, the platform-independent tests and Windows cross-compilation can run:

```bash
dotnet run --project Windows/Slightshot.Core.Tests -c Release
dotnet build Windows/Slightshot -c Release
```

The fixtures use synthetic content. They are native renderer evidence, not a
video of a person using the Windows desktop. Manual Windows acceptance still
needs capture/clipboard/print/tray testing, mixed-DPI multi-monitor dragging,
keyboard focus, and a real desktop video. The Mac cannot run WPF.

Settings follow the Windows light/dark app preference with grouped panels,
rounded segmented tabs, switch controls and matching subdued colours. CI renders
both themes. The tray reuses the Mac menu artwork (tinted for the taskbar theme)
and the Windows executable icon is converted from the existing Mac app artwork.

Windows uses Segoe UI and equivalent custom vector icons because Apple's system
fonts and SF Symbols are platform-specific. Frosted material and text shadow are
approximations of AppKit rather than identical OS rendering. Windows update
delivery is manual; no signing, installer or automatic updater is provided in this
initial port. GDI screenshot capture targets the ordinary desktop; protected video
and HDR-specific colour management are outside this first version. Screen recording
is tracked separately so it can be reviewed independently from the capture port.

References: [Windows targeting from macOS](https://learn.microsoft.com/en-us/dotnet/core/tools/sdk-errors/netsdk1100),
[Microsoft's DPI guidance](https://learn.microsoft.com/en-us/windows/win32/hidpi/high-dpi-desktop-application-development-on-windows),
[WPF per-monitor DPI sample](https://github.com/microsoft/WPF-Samples/tree/main/PerMonitorDPI).
