# Contributing

Thanks for looking. Slightshot is small on purpose, so contributions are easy to
review.

## Getting set up

Clone the repository, then use the tools for your platform:

```bash
git clone https://github.com/jmpijll/slightshot.git
cd slightshot
```

On macOS, you need macOS 27 and the Xcode 27 command line tools. Run `make run`.
There is no `.xcodeproj` — it is a plain Swift package, so `open Package.swift`
works if you want Xcode. `make run` builds `build/Slightshot.app`, signs it with
an available Developer ID or an ad-hoc signature, and launches it.

| Command | Result |
| --- | --- |
| `make build` | Debug build |
| `make app` | App bundle, signed locally |
| `make dmg` | Disk image |
| `make release` | App and disk image, with notarisation and stapling |
| `make icon` | Regenerate app, menu bar and README artwork |
| `make lint` | Run SwiftLint, if installed |
| `make test` | Verify raster effects, annotation export and recording |

To write Mac debug logs to the terminal:

```bash
SLIGHTSHOT_DEBUG=1 ./build/Slightshot.app/Contents/MacOS/Slightshot
```

On Windows, install the [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0)
and run `dotnet run --project Windows/Slightshot`. Use a supported Windows 11
release. See [the Windows guide](docs/windows.md#run-and-build) for packaging,
installer builds and native renderer/recording checks.

## Before opening a pull request

Run the checks appropriate to your change:

- macOS: `make lint` passes (`swiftlint --strict`), `swift build` is warning-free,
  and `make test` passes for capture, annotation or recording changes.
- Windows: `dotnet run --project Windows/Slightshot.Core.Tests -c Release` and
  `dotnet build Windows/Slightshot -c Release` pass. Review the Windows CI native
  rendering/recording results; installer changes also need its lifecycle checks.
- Shared icons: `python3 Scripts/generate_ui_icons.py --check` passes.
- Release scripts: `python3 -m unittest discover -s Tests -v` passes.
- Run the app and use the feature you changed on its native platform. Clearly
  state when only cross-building or automated fixtures were available.
- The PR description includes a screenshot or short video of the implemented
  change, following the visual evidence rule below.

## Visual review evidence

Every PR includes a screenshot or short video showing what the change does or
how it works. Embed the evidence in the description so a reviewer can assess
the behavior directly. Show the interaction and result; use a before/after
sequence or video when a single screenshot does not explain the change.

Capture the working app on each platform whose visible behavior changes, and
identify the platform and source commit. Automated captures of native app
windows are welcome: label fixture inputs and automated interaction clearly.
Mockups and generated illustrations do not demonstrate an implemented feature.
For internal changes, show the relevant measured or validation result; for
documentation changes, show the rendered content that changed.

Keep captures focused and free of personal information. Attach them to the PR
or store them in `docs/review/<change>/`; temporary CI artifacts alone are not
a lasting review record. Include the checks run separately: visual evidence
helps review and complements tests.

## The one hard rule

**Interaction fidelity with Lightshot wins.** If a change makes Slightshot
faster or prettier but moves a toolbar, changes a shortcut, or adds a step, it
probably belongs behind a setting rather than in the default path. People are
switching to this because their hands already know Lightshot.

That applies to behaviour, not implementation — the internals should be as
modern and as fast as we can make them.

## Where things live

| Path | What |
| --- | --- |
| `Sources/Slightshot/Capture` | ScreenCaptureKit, permissions |
| `Sources/Slightshot/Overlay` | The capture UI — the heart of the app |
| `Sources/Slightshot/Editor` | Annotation model and the exporter |
| `Sources/Slightshot/Services` | Hotkeys, settings, output, updates |
| `Sources/Slightshot/Preferences` | SwiftUI settings window |
| `Windows/Slightshot` | WPF capture/editor, settings, output and recording |
| `Windows/Slightshot.Core` | Platform-independent Windows geometry and raster logic |
| `Windows/Slightshot.Core.Tests` | Windows core regression checks |
| `Windows/Installer` | Per-user setup configuration and branding |
| `Resources/UI` | Original toolbar glyphs shared by both platforms |
| `Scripts/` | Bundle, sign, notarise, disk image, Windows packaging and icons |

## macOS coordinate systems

Everything drawn in the overlay uses **flipped display points, origin top-left**.
`Annotation.draw()` shares vector drawing between the live canvas and exports.
Blur and pixelation use the same raster compositor for preview and export,
processing annotations in order so they include earlier marks. The canvas
caches the committed image and processes only the live rectangle while dragging.
Add vector tools to `Annotation.Shape`; raster tools also need compositor support.

`ScreenshotView`, `DimView` and `MagnifierView` are deliberately *not* flipped,
because `CALayer.contents` and `CGContext.draw(_:in:)` render images upright in
default geometry. Each one converts at its own boundary.
